Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$fixturePath = Join-Path $repositoryRoot 'Tests\Hardware\Fixtures\thai-raster-commissioning-v1.json'
$schemaPath = Join-Path $repositoryRoot 'Tests\Hardware\Schemas\commissioning-fixture-v1.schema.json'

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

foreach ($requiredPath in @($fixturePath, $schemaPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

$fixtureJson = Get-Content -LiteralPath $fixturePath -Raw

Assert-Equal `
    -Name 'fixture schema validation' `
    -Expected $true `
    -Actual ($fixtureJson | Test-Json -SchemaFile $schemaPath)

$fixture = $fixtureJson | ConvertFrom-Json

Assert-Equal -Name 'fixture is synthetic' -Expected $true -Actual $fixture.syntheticData
Assert-Equal -Name 'fixture item count' -Expected 4 -Actual $fixture.items.Count
Assert-Equal `
    -Name 'test-only title present' `
    -Expected $true `
    -Actual ([bool]($fixture.title -match 'TEST ONLY'))
Assert-Equal `
    -Name 'Thai content present' `
    -Expected $true `
    -Actual ([bool]($fixtureJson -match '[ก-๙]'))

Write-Output 'TEST-0010B-21C: PASS'
Write-Output 'Verified: sanitized synthetic fixture, schema compliance, Thai coverage, and explicit test-only labeling.'
