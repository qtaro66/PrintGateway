# TASK: PrintJobStore.ps1 Improvement & Hardening Plan
# Target File: C:\PrintGateway\Lib\PrintJobStore.ps1
# Context: PrintGateway SQLite Job Store & Audit Event Pipeline

---

## 1. Objective (เป้าหมาย)
ปรับปรุงและเพิ่มความแข็งแกร่ง (Hardening) ให้กับไลบรารี `C:\PrintGateway\Lib\PrintJobStore.ps1` ตามข้อสังเกตเชิงสถาปัตยกรรม 3 ข้อ:
1. ปลดล็อก Hardcoded User Path ของ `sqlite3.exe` ให้รองรับทั้ง Portable Path และ Environment Path
2. เพิ่มฟังก์ชัน `Get-PrintJobStoreStaleSendingJobs` สำหรับค้นหางานที่ค้างสถานะ `SENDING` ตอน Service บูตระบบ
3. เสริมความปลอดภัยการ Escape ข้อความใน Dynamic SQL สำหรับ Audit Log และ Event Message

---

## 2. Action Items & Implementation Details (ขั้นตอนการปฏิบัติงาน)

### Task 1: กำหนดค่า Default Path แบบ Dynamic สำหรับ SQLite
**ปัญหาปัจจุบัน:** ทุกฟังก์ชันระบุ default parameter เป็น:
`$SqlitePath = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\sqlite3.exe"`
ทำให้ระบบรันภายใต้ Windows Service หรือเครื่องอื่นที่มี User Name ต่างกันไม่ได้

**แนวทางแก้ไข:**
เพิ่มการค้นหา Path อัตโนมัติที่ต้นไฟล์ (หลัง `Set-StrictMode -Version Latest`):
```powershell
# Dynamic SQLite resolution:
# Priority 1: C:\PrintGateway\Bin\sqlite3.exe
# Priority 2: PATH environment variable (where.exe sqlite3)
# Priority 3: Fallback to local Android SDK path
$script:DefaultPrintJobStoreSqlitePath = if (Test-Path "C:\PrintGateway\Bin\sqlite3.exe") {
    "C:\PrintGateway\Bin\sqlite3.exe"
}
elseif ($null -ne (Get-Command "sqlite3.exe" -ErrorAction SilentlyContinue)) {
    (Get-Command "sqlite3.exe").Source
}
elseif (Test-Path (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\sqlite3.exe")) {
    Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\sqlite3.exe"
}
else {
    "sqlite3.exe"
}
```
และเปลี่ยน default parameter ในทุกฟังก์ชันเป็น:
```powershell
[string]$SqlitePath = $script:DefaultPrintJobStoreSqlitePath
```

---

### Task 2: เพิ่มฟังก์ชัน `Get-PrintJobStoreStaleSendingJobs`
**ปัญหาปัจจุบัน:** มีฟังก์ชัน `Recover-PrintJobStoreSendingJob` ที่รับ `$JobId` รายตัว แต่ยังไม่มีฟังก์ชันดึงรายชื่อ Job ทั้งหมดที่ค้างสถานะ `SENDING` เพื่อนำมารัน Batch Recovery ตอนเริ่มระบบ

**แนวทางแก้ไข:**
เพิ่มฟังก์ชันใหม่ต่อท้ายไฟล์:
```powershell
function Get-PrintJobStoreStaleSendingJobs {
    <#
    .SYNOPSIS
        Retrieves all Job IDs currently stuck in the SENDING status.
    .DESCRIPTION
        Used during service startup or health-check routines to discover
        unresolved jobs that require crash recovery to UNKNOWN status.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [string]$SqlitePath = $script:DefaultPrintJobStoreSqlitePath
    )

    $sql = @"
SELECT JobId
FROM print_jobs
WHERE Status = 'SENDING'
ORDER BY UpdatedAtUtc ASC;
"@

    $rawOutput = Invoke-PrintJobStoreSqlite `
        -DatabasePath $DatabasePath `
        -Sql $sql `
        -SqlitePath $SqlitePath

    $rows = @($rawOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    return $rows
}
```

---

### Task 3: เสริมการตรวจเช็กและ Escaping ให้กับ Audit Messages
**ปัญหาปัจจุบัน:** ในฟังก์ชัน `Complete-PrintJobStoreAttempt` และ `Recover-PrintJobStoreSendingJob` มีการนำข้อความ Error / Reason เข้าไปประกอบใน SQL Statement

**แนวทางแก้ไข:**
- ตรวจสอบให้แน่ใจว่า `$escapedReason` และ `$sqlError` มีการ Escape Single Quote (`'`) เป็น `''` อย่างเข้มงวดเสมอ
- ในส่วน `INSERT INTO job_events` ถ้ามีการนำ `$ErrorMessage` เข้ามาเป็นส่วนหนึ่งของ Message ให้ใช้ฟังก์ชัน `ConvertTo-SqlNullableText` หรือตัดข้อความให้ไม่เกินขนาดความยาวที่กำหนด (เช่น ป้องกัน SQL Injection หรือ Syntax Error จาก String ที่มีอักขระพิเศษ)

---

## 3. Verification & Validation Steps (การตรวจสอบหลังดำเนินการ)

เมื่อ Agent ดำเนินการแก้ไขเสร็จแล้ว ต้องรันคำสั่งตรวจสอบดังนี้:

1. **AST Parser Syntax Check:**
   ```powershell
   $errors = $null
   [System.Management.Automation.Language.Parser]::ParseFile("C:\PrintGateway\Lib\PrintJobStore.ps1", [ref]$null, [ref]$errors) > $null
   if ($errors.Count -eq 0) {
       "PrintJobStore.ps1 SYNTAX PASS"
   } else {
       $errors | Format-List
   }
   ```

2. **Integration Verification (Mock Test):**
   - ทดสอบเรียกฟังก์ชัน `Get-PrintJobStoreStaleSendingJobs` กับ Database จำลอง
   - ทดสอบว่า `$script:DefaultPrintJobStoreSqlitePath` สามารถ Resolve Path ของ SQLite บนเครื่องได้ถูกต้อง
