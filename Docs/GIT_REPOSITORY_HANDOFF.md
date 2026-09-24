# Git Repository Handoff

## Scope

This repository baseline contains the PrintGateway implementation through B-18BO, B-19A through B-19E hardening, B-20A deployment provisioning, and the successful real Epson integration test performed on 2026-09-24.

## Implemented process

1. Added atomic `RECOVERED_STALE_SENDING` audit creation in the same SQLite transaction as `SENDING -> UNKNOWN`.
2. Preserved `Attempt`, `SendStarted`, and all ACK evidence during recovery.
3. Blocked repeated recovery when no row changes.
4. Replaced the in-memory manager path with durable SQLite-backed job management.
5. Added startup recovery and cross-process restart verification.
6. Added fail-closed global worker mutex handling.
7. Added SQLite path resolution and deployment preflight.
8. Added atomic production-database provisioning.
9. Added local group `PrintGatewayLocalUsers` and restricted Data-directory ACLs.
10. Verified all non-printer tests and then completed a real Epson print with a matching Process ID ACK.

## Final real-printer evidence

- Job ID: `ORDER-B17-004`
- Process ID: `0020`
- Final state: `COMPLETED`
- Attempt: `1`
- Raster bytes: `47592`
- ACK received: `True`
- ACK valid: `True`
- Returned Process ID: `0020`
- ACK bytes: `37 22 30 30 32 30 00`
- ACK elapsed: `304 ms`
- Persisted audit sequence: `CREATED -> STARTED -> COMPLETED`
- SQLite integrity check: `ok`

The runtime evidence remains in the local production database and is not committed to Git.

## Files to commit

### Core code

- `Lib/EpsonRaster.ps1`
- `Lib/EpsonTransport.ps1`
- `Lib/PrintJobStore.ps1`
- `Lib/PrintJobManager.ps1`

### Schema and deployment

- `Data/schema.sql`
- `Tools/Initialize-PrintGatewayDatabase.ps1`
- `Tools/Set-PrintGatewayLocalAccess.ps1`
- `Tools/Test-PrintGatewayDeployment.ps1`
- `Tools/Complete-PrintGatewayLocalDeployment.ps1`

### Tests

- `Tests/Invoke-PrintGatewayTests.ps1`: public entrypoint for the complete safe suite
- `Tests/PrintGateway.Tests.ps1`: safe-suite orchestrator and CI exit-code handling
- `Tests/Invoke-PrintGatewayHardwareTest.ps1`: explicit hardware-print safety gate
- `Tests/Cases/Invoke-PrintGatewayIntegrationScenario.ps1`: internal NoSend and simulated transport scenario
- `Tests/Cases/TEST-0010B-18BO.ps1` through `TEST-0010B-20A.ps1`: isolated regression cases
- `Tests/Legacy/TEST-0010B-10.ps1` through `TEST-0010B-16B.ps1`: historical hardware-development tests

### Documentation and Git metadata

- `README.md`
- `Docs/GIT_REPOSITORY_HANDOFF.md`
- `AI_REVIEW_AND_HARDENING_RECOMMENDATIONS.md`
- `Lib/TASK_PRINTJOBSTORE_IMPROVEMENTS.md`
- `.gitignore`
- `.gitattributes`

## Files intentionally excluded

- `Data/printgateway.db`: production job and audit state
- `Data/schema-test.db`, `schema-v2-test.db`, `schema-v3-test.db`: generated test databases
- `Tests/work/`: temporary test databases
- `Tests/TEST-0010B-17A.before-finally.ps1`: obsolete pre-migration snapshot
- `Bin/sqlite3.exe`: external dependency; do not redistribute without a separate licensing decision
- Printer photographs and user-profile temporary files

## Validation commands

Parser validation for tracked PowerShell files:

```powershell
$files = Get-ChildItem 'C:\PrintGateway' -Recurse -Filter '*.ps1' |
    Where-Object FullName -NotLike '*TEST-0010B-17A.before-finally.ps1'

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors.Count -gt 0) {
        throw "Parser failure: $($file.FullName): $($errors.Message -join '; ')"
    }
}
```

Non-printer regression suite:

```powershell
& 'C:\PrintGateway\Tests\Invoke-PrintGatewayTests.ps1'
```

## GitHub Desktop workflow

1. Open GitHub Desktop.
2. Select **File -> New repository**.
3. Set **Name** to `PrintGateway`.
4. Set **Local path** to `C:\` so the repository path resolves to the existing `C:\PrintGateway` folder. If GitHub Desktop refuses a non-empty destination, use **File -> Add local repository**, select `C:\PrintGateway`, and allow GitHub Desktop to create the repository when offered.
5. Do not select a generated `.gitignore` or license; both decisions are already represented locally, and no license has been chosen.
6. Review the Changes list. No `.db`, `Tests/work`, `sqlite3.exe`, photograph, or obsolete snapshot should appear.
7. Commit with a baseline message such as `Baseline: verified PrintGateway durable Epson integration`.
8. Select **Publish repository**.
9. Choose repository visibility deliberately. Prefer **Private** until printer addresses, operational assumptions, and licensing have been reviewed.
10. Confirm the remote file list does not contain runtime databases or local binaries.

Publishing transmits the tracked source and documentation to GitHub. Repository name, owner, and visibility must be chosen by the repository owner at publish time.
