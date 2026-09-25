# Production DevSecOps & AI Review Integration Specification
## Master Directive for AI Implementation Agent

**Document Version:** 2.0 (Hardened & Actionable)  
**Target Environment:** GitHub Actions, PowerShell Core / Windows Runner, Snyk, SonarQube Cloud, CodeRabbit, Qodo  
**Core Principle:** Deterministic tools decide if code is safe to merge; AI tools help humans understand logic; Humans make the final decision.

---

## 1. Architectural Blueprint

```text
                                Pull Request Event
                                        │
           ┌────────────────────────────┴────────────────────────────┐
           ▼                                                         ▼
[ Tier 1: Deterministic Gates ]                             [ Tier 2: AI Advisory ]
  (Status Checks: PASS / FAIL)                                (Inline Comments & Reviews)
  ├── Pester Test Suite (Required)                            ├── CodeRabbit (Logic, Race Conditions, Edge Cases)
  ├── Snyk Code SAST (Required)                               └── Qodo / PR-Agent (Unit Test Generation & Coverage)
  └── SonarQube Cloud Quality Gate (Required)                                │
           │                                                                 ▼
           ▼                                                    Non-blocking Developer Guidance
  All Checks Must Pass                                            (Does NOT block merge)
           │
           ▼
  Human Review Approval
           │
           ▼
         MERGE
```

---

## 2. Hardened Configuration Files

### 2.1 Pinned GitHub Actions Workflow (`.github/workflows/tier1-gates.yml`)

Save this file to: `.github/workflows/tier1-gates.yml`

```yaml
name: "Tier 1: Deterministic Quality & Security Gates"

on:
  pull_request:
    branches: [ main, master ]
  push:
    branches: [ main, master ]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  pester-tests:
    name: "Pester Test Suite"
    # Use windows-latest if System.Drawing (GDI+) is executed in tests, otherwise ubuntu-latest
    runs-on: windows-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1 pinned

      - name: Execute Pester Verification
        shell: pwsh
        run: |
          $pesterConfig = [PesterConfiguration]::Default
          $pesterConfig.Run.Path = @("./Tests")
          $pesterConfig.Output.Verbosity = 'Detailed'
          $pesterConfig.Run.Exit = $true
          Invoke-Pester -Configuration $pesterConfig

  snyk-code-security:
    name: "Snyk Code Security Scan"
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1 pinned

      - name: Setup Snyk CLI
        uses: snyk/actions/setup@80682cf8946274e92a83adbb07ebf059cb2ec7a2 # v0.4.0 pinned

      - name: Execute Snyk SAST
        env:
          SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
        run: |
          # Fails execution only on High/Critical source code vulnerabilities
          snyk code test --severity-threshold=high

  sonar-quality-gate:
    name: "SonarQube Cloud Quality Gate"
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code (Full History for Blame/Line Matching)
        uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1 pinned
        with:
          fetch-depth: 0

      - name: SonarQube Cloud Scan
        uses: SonarSource/sonarqube-scan-action@480373ab1a19a9e3e3eb6f0d922a902b4d95267b # v4.2.1 pinned
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
```

---

### 2.2 SonarQube Cloud Properties (`sonar-project.properties`)

Save this file to: `sonar-project.properties`

```properties
# File: sonar-project.properties
sonar.projectKey=YOUR_ORGANIZATION_KEY_PROJECT_KEY
sonar.organization=YOUR_ORGANIZATION_KEY

# Source paths - specify exact folders once repo structure is inspected
sonar.sources=Lib,Src
sonar.exclusions=**/Tests/work/**,**/*.tmp,**/bin/**,**/obj/**

# Test paths
sonar.tests=Tests
sonar.test.inclusions=**/*Test*.ps1,**/*.spec.ts,**/*.test.js

# Encoding
sonar.sourceEncoding=UTF-8

# Quality Gate Policy on New Code:
# - 0 New Bugs
# - 0 New Vulnerabilities
# - Security Hotspots Reviewed
# - Coverage on New Code >= 70% (target 80% as maturity grows)
```

---

### 2.3 CodeRabbit Review Directives (`.coderabbit.yaml`)

Save this file to: `.coderabbit.yaml`

```yaml
version: 2
language: "en-US"

early_access: false

reviews:
  profile: "chill"
  request_changes_workflow: false # Must NEVER block PRs automatically
  high_level_summary: true
  poem: false
  
  instructions: |
    Role: Senior Software Architect and Logic Reviewer.
    Scope:
    - Review exclusively: Business Logic correctness, Concurrency, Mutex/Race conditions, Resource disposal (.Dispose()), Error-Action handling, State Machine invariants.
    - Specifically for PowerShell: verify StrictMode compatibility, integer division vs -shr bitwise operations, proper encoding (UTF-8 BOM), and SQLite transaction boundaries.
    - DO NOT comment on formatting, styling, or trivial lint rules already covered by SonarQube.
    - DO NOT duplicate standard SAST findings handled by Snyk.

  auto_review:
    enabled: true
    drafts: false

  tools:
    ast-grep:
      enabled: false

chat:
  auto_reply: true
```

---

### 2.4 Qodo / PR-Agent Configuration (`.pr_agent.toml`)

Save this file to: `.pr_agent.toml`

```toml
[pr_reviewer]
# Disable generic review comments to eliminate noise and overlap with CodeRabbit
enable_review_labels_effort = false
num_code_suggestions = 1
inline_code_comments = false

[pr_description]
# Leave PR description to CodeRabbit / human authors
publish_description_as_comment = false

[pr_test]
# Focus exclusively on unit testing and coverage synthesis
enable_auto_generate_tests = true
num_tests = 4
testing_framework = "Pester"

[config]
verbosity_level = 0
enable_command_triggers = true # Trigger on demand via: /test or /improve
```

---

## 3. GitHub Branch Protection / Ruleset Enforcement

Configure the repository branch protection rules on `main`:

1. **Require a pull request before merging:**
   - Require approvals: **>= 1 human engineer**
   - Dismiss stale pull request approvals when new commits are pushed: **Enabled**
2. **Require status checks to pass before merging:**
   - Search and select **ONLY** Tier 1 checks:
     - ✅ `Pester Test Suite`
     - ✅ `Snyk Code Security Scan`
     - ✅ `SonarQube Cloud Quality Gate`
   - ⚠️ **DO NOT** select CodeRabbit or Qodo as required checks.
3. **Require conversation resolution before merging:** **Enabled**
4. **Block force pushes and branch deletions:** **Enabled**

---

## 4. AI Implementation Agent Protocol (Step-by-Step Task)

When an AI Agent is tasked with setting up or maintaining this infrastructure, it must follow this sequence:

1. **Step 1: Inspect Repository (Read-Only):**
   - Verify existing directories (`Lib/`, `Tests/`, `Data/`).
   - Identify existing test runners (e.g., Pester tests in `Tests/`).
   - Confirm whether `System.Drawing` or Windows-specific APIs are used (to select `windows-latest` vs `ubuntu-latest`).
2. **Step 2: Check Existing CI:**
   - Check `.github/workflows/` for existing workflows to prevent overwriting custom steps.
3. **Step 3: Deploy Configurations:**
   - Commit `.coderabbit.yaml` and `.pr_agent.toml` to repository root.
   - Commit `sonar-project.properties` with verified folder paths.
   - Commit `.github/workflows/tier1-gates.yml` using pinned commit SHAs.
4. **Step 4: Local Verification:**
   - Run Pester tests locally to ensure baseline tests pass.
   - Verify YAML/TOML syntax using a parser before committing.
5. **Step 5: Report Status:**
   - Output summary of configured tools, required GitHub Secrets (`SNYK_TOKEN`, `SONAR_TOKEN`), and protected branch policies.
