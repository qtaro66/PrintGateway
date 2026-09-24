# PrintGateway B-18BO through B-19E — Formal Architecture Review & Hardening Recommendations

**Target System:** PrintGateway SQLite Job Store & Durable Manager  
**Reviewed Documents:** `PrintGateway-B18BO-B19E-AI-Review.md`  
**Test Suite Verified:** `TEST-0010B-18BO.ps1` through `TEST-0010B-19E.ps1` (**ALL PASS 6/6**)  
**Generated Date:** 2026-09-24 (Asia/Bangkok)

---

## 1. Executive Summary & Verification Findings

The durable state-management implementation introduced across milestones **B-18BO through B-19E** has been audited and verified via automated execution of the test suite. The transition from an in-memory hashtable to the durable, atomic SQLite-backed architecture is structurally sound and satisfies all critical requirements for mission-critical POS environments.

### Core Checklist Verification Matrix

| Audit Checklist Item | Status | Verified Technical Evidence |
| :--- | :---: | :--- |
| **Atomic `changes()` Capture** | **PASS** | Captured into temporary table `_pg_changes` immediately following `UPDATE` across all transitions (`Start-Attempt`, `Complete-Attempt`, `Start-Retry`, and `Bulk-Recovery`). Prevents downstream queries/triggers from overwriting rowcount. |
| **Zero-Row Audit Suppression** | **PASS** | Audit events are conditioned on `(SELECT Changed FROM _pg_changes) = 1` or candidate joins. Zero rows updated produces zero audit records. |
| **Atomic Rollback on Audit Failure** | **PASS** | State mutation and event insertion reside in single `BEGIN IMMEDIATE ... COMMIT` blocks with `PRAGMA foreign_keys = ON`. Foreign key or constraint violations cleanly roll back the state transition. |
| **Bulk Recovery Idempotency** | **PASS** | `Recover-PrintJobStoreSendingJobs` captures candidate `SENDING` rows first; a successive execution changes 0 rows and inserts 0 events. |
| **Evidence Preservation** | **PASS** | Recovery updates only `Status -> 'UNKNOWN'`, `LastError`, and `UpdatedAtUtc`. Transport/ACK metrics (`Attempt`, `SendStarted`, `AckReceived`, `AckValid`, `ReturnedProcessId`, `AckBytesHex`, `AckElapsedMs`) are preserved intact. |
| **Manager State Machine Routing** | **PASS** | `Start-PrintGatewayJobAttempt` routes `QUEUED` to initial attempt and `FAILED` to safe retry. All other states (`UNKNOWN`, `COMPLETED`, `SENDING`) throw invariant violations. |
| **Full Payload Identity** | **PASS** | SHA-256 fingerprint encompasses the entire outbound byte sequence (Init + StoreHeader + Raster + PrintGraphics + Feed + Cut + ProcessIdCmd). Prevents payload mutation under the same Job ID. |
| **Fail-Closed Terminal Validation** | **PASS** | Normalization enforces: `COMPLETED` requires `SendStarted=1`, `AckReceived=1`, `AckValid=1`, and `ReturnedProcessId == ProcessId`. Any anomaly fails closed to `UNKNOWN`. |
| **Pre-Epson Safety Gate** | **PASS** | The internal integration scenario defaults to `NoSend`; real printing is exposed through `Invoke-PrintGatewayHardwareTest.ps1` and requires both a real `-PrinterIp` and `-ConfirmHardwarePrint`. |

---

## 2. Findings and Actionable Recommendations (Ordered by Severity)

### Finding 1 [HIGH SEVERITY]: Exclusive-Startup Concurrency Assumption
* **Observation:** `Recover-PrintGatewaySendingJobs` unconditionally converts all `SENDING` jobs to `UNKNOWN` on startup. While `BEGIN IMMEDIATE` serializes SQLite writes, it cannot detect if an orphaned or zombie worker process from a previous crash is still actively transmitting bytes over TCP port 9100. If that worker subsequently succeeds, while an operator manually retries the `UNKNOWN` job, duplicate tickets will print.
* **Actionable Recommendation:**
  1. **Single-Instance Process Lock:** Implement a system-wide Named Mutex in the service startup bootstrap:
     ```powershell
     $mutex = New-Object System.Threading.Mutex($true, "Global\PrintGateway_ExclusiveWorker", [ref]$isAcquired)
     if (-not $isAcquired) {
         throw "Another instance of PrintGateway is currently executing. Bulk recovery aborted to prevent split-brain delivery."
     }
     ```
  2. **Worker Heartbeat / Staleness Threshold (Optional for Distributed Setups):** Add a `HeartbeatUtc` column to `print_jobs`. Limit bulk recovery to jobs where `UpdatedAtUtc <= datetime('now', '-30 seconds')`.

---

### Finding 2 [MEDIUM SEVERITY]: Production Database & Path Decoupling
* **Observation:**
  1. Earlier versions used a developer-specific SQLite path under the local user profile; the hardened resolver now derives that fallback from `$env:LOCALAPPDATA`.
  2. The production database file `C:\PrintGateway\Data\printgateway.db` is not yet provisioned.
* **Actionable Recommendation:**
  1. Apply dynamic path resolution at the head of `PrintJobStore.ps1` and `PrintJobManager.ps1`:
     - Priority 1: `C:\PrintGateway\Bin\sqlite3.exe`
     - Priority 2: System `PATH` (`where.exe sqlite3`)
     - Priority 3: Fallback developer profile path.
  2. Execute an automated provisioning script:
     ```powershell
     & $sqlitePath C:\PrintGateway\Data\printgateway.db ".read C:\PrintGateway\Data\schema.sql"
     ```
  3. Ensure NTFS ACLs restrict write permissions on `C:\PrintGateway\Data\` to the dedicated Service Account and Administrators.

---

### Finding 3 [MEDIUM SEVERITY]: Git Baseline & Configuration Drift Prevention
* **Observation:** `C:\PrintGateway` currently lacks a Git repository, relying instead on static SHA-256 hash manifest handoffs.
* **Actionable Recommendation:**
  1. Initialize Git repository at `C:\PrintGateway`:
     ```powershell
     git -C C:\PrintGateway init
     git -C C:\PrintGateway add Lib/ Tests/ Data/
     git -C C:\PrintGateway commit -m "Baseline: Milestone B-18BO through B-19E verified state"
     ```
  2. Add `.gitignore` to exclude transient test artifacts:
     ```gitignore
     Tests/work/
     *.tmp
     *.db-journal
     *.db-wal
     ```

---

### Finding 4 [LOW SEVERITY / CODE HYGIENE]: Parser Formatting & Legacy File Deprecation
* **Observation:**
  1. Multiple function definitions in `PrintJobStore.ps1` are formatted on the same line as the closing brace of preceding functions (e.g., `}function New-PrintJobStoreJob`).
  2. `C:\PrintGateway\Tests\TEST-0010B-17A.before-finally.ps1` represents an unmigrated snapshot referencing obsolete in-memory Manager signatures.
* **Actionable Recommendation:**
  1. Format function headers with standard line breaks for cleaner `git diff` inspections.
  2. Archive or delete `TEST-0010B-17A.before-finally.ps1` to prevent inadvertent test invocation during CI/CD.

---

## 3. Real Device Testing (Epson TM-T82X) — Go / No-Go Decision

### Current Assessment: **CONDITIONAL GO 🟢**

The software stack is certified ready for physical hardware verification on Epson TM-T82X under the following operational constraints:

1. **Explicit Opt-In Required:** Must specify `-TransportMode Printer` explicitly.
2. **Fresh Identity:** Must supply a new, unique `JobId` (e.g., `ORDER-REAL-001`) and four-digit `ProcessId` (e.g., `0030`) to avoid intentional idempotency collision against historical fixture records.
3. **Dedicated Target DB:** Run against `printgateway.db` initialized with `schema.sql` rather than shared test fixtures.
4. **Physical Inspection:** Verify paper feed, graphic raster fidelity, partial cut, and printer response frame matching `0x37, 0x22, <ProcessId>, 0x00`.
