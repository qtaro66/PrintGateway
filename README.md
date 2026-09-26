# PrintGateway

PrintGateway is a Windows PowerShell 7 integration for direct ESC/POS printing to an Epson printer over raw TCP port 9100. It renders Thai text as raster graphics, records durable job state in SQLite, validates Epson Process ID acknowledgements, and blocks unsafe automatic retries when delivery is uncertain.

## Verified baseline

The current baseline has been verified through a real Epson print:

- Raster rendering and raw TCP transport passed.
- Process ID `0020` received a matching ACK.
- Durable state completed as `QUEUED -> SENDING -> COMPLETED`.
- Audit events `CREATED`, `STARTED`, and `COMPLETED` were persisted.
- Startup recovery converts stale `SENDING` jobs to `UNKNOWN` atomically.
- `UNKNOWN` and completed jobs are blocked from unsafe resubmission.
- A global mutex prevents multiple active workers.
- The integration test defaults to `NoSend`; printer access requires explicit `-TransportMode Printer`.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Lib/EpsonRaster.ps1` | Raster rendering for Epson graphics commands |
| `Lib/EpsonTransport.ps1` | TCP transport, print command sequence, Process ID ACK parsing |
| `Lib/PrintJobStore.ps1` | Atomic SQLite job transitions and audit events |
| `Lib/PrintJobManager.ps1` | Durable job-manager API, startup recovery, global mutex |
| `Lib/PrintJobContract.ps1` | Strict POS-to-PrintGateway v1 request parsing and canonical request fingerprinting |
| `Data/schema.sql` | Version-controlled SQLite schema |
| `Contracts/print-job-v1.schema.json` | Versioned JSON Schema for POS print-job requests |
| `Tools/` | Database provisioning, local-account ACL setup, deployment preflight |
| `Tests/Invoke-PrintGatewayTests.ps1` | Single entrypoint for all safe regression tests |
| `Tests/Invoke-PrintGatewayHardwareTest.ps1` | Explicitly confirmed real-printer test |
| `Tests/Cases/` | Internal durable-state, integration-simulation, recovery, mutex, and deployment cases |
| `Tests/Legacy/` | Historical hardware-development scripts retained for reference |
| `Docs/GIT_REPOSITORY_HANDOFF.md` | Baseline, commands, exclusions, and GitHub Desktop workflow |

Runtime `.db` files are deliberately excluded from Git. Never commit `Data/printgateway.db` because it contains operational state and delivery evidence.

## Requirements

- Windows 10 or 11
- PowerShell 7
- `sqlite3.exe`, resolved in this order:
  1. An explicit `-SqlitePath`
  2. `C:\PrintGateway\Bin\sqlite3.exe`
  3. `sqlite3.exe` available on `PATH`
  4. The existing local Android SDK fallback, when present
- Epson-compatible ESC/POS printer for the hardware test only

The deployed path is currently expected to be `C:\PrintGateway`. Several deployment and historical test scripts intentionally use this fixed path.

## Local deployment

Open PowerShell as Administrator and run:

```powershell
& 'C:\PrintGateway\Tools\Complete-PrintGatewayLocalDeployment.ps1' `
    -LocalAccount $env:USERNAME
```

Add future local accounts with:

```powershell
& 'C:\PrintGateway\Tools\Set-PrintGatewayLocalAccess.ps1' `
    -LocalAccount @($env:USERNAME, 'another-local-user') `
    -Apply
```

Sign out and back in after changing local-group membership.

## Safe verification

Run deployment preflight without printing:

```powershell
& 'C:\PrintGateway\Tools\Test-PrintGatewayDeployment.ps1' `
    -ServiceAccount $env:USERNAME
```

Run the complete safe regression suite:

```powershell
& 'C:\PrintGateway\Tests\Invoke-PrintGatewayTests.ps1'
```

The suite uses temporary databases and simulated transport outcomes. It does not connect to the printer.

## Real-printer safety gate

The following command performs a real print to the configured printer. Confirm the printer IP, paper, cover, and online state first:

```powershell
& 'C:\PrintGateway\Tests\Invoke-PrintGatewayHardwareTest.ps1' `
    -PrinterIp '<printer-ip>' `
    -DatabasePath 'C:\PrintGateway\Data\printgateway.db' `
    -ConfirmHardwarePrint
```

Do not immediately retry a timeout or `UNKNOWN` result. Inspect the durable job record first because bytes may already have reached the printer.

The default printer address in test scripts is the non-routable documentation address `192.0.2.10`. A real address must be supplied explicitly for a hardware test.

## POS print-job contract

The first POS integration boundary is the versioned JSON contract in
`Contracts/print-job-v1.schema.json`. A complete example is available at
`Contracts/examples/print-job-v1.example.json`.

Load and validate a request without connecting to a printer:

```powershell
. 'C:\PrintGateway\Lib\PrintJobContract.ps1'

$json = Get-Content `
    -LiteralPath 'C:\PrintGateway\Contracts\examples\print-job-v1.example.json' `
    -Raw

$request = ConvertFrom-PrintGatewayJobJson -Json $json
```

The parser rejects unknown or duplicate properties, unsupported contract
versions, invalid identifiers, non-UTC timestamps, empty payloads, excessive
nesting, and requests larger than 256 KiB. `RequestFingerprint` represents the
canonical request. It is deliberately separate from the existing
`PayloadFingerprint`, which represents the final rendered ESC/POS bytes.

This milestone defines and validates the integration boundary only. It does not
yet expose an HTTP endpoint, run a Windows service, render arbitrary templates,
or send the request to a printer.

## Current known limitation

The verified test receipt wrapped the final `***` marker of the first long note onto a separate line. This is a presentation issue in text wrapping, not a transport, ACK, or durable-state failure.

No open-source license has been assigned. Add a license only after the repository owner chooses one.
