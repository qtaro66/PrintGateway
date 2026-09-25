# GitHub DevSecOps & AI Review Integration Guide
## Multi-Agent & Multi-Tool Configuration: Snyk + SonarCloud + CodeRabbit + Qodo

**Target Platform:** GitHub (GitLab / Bitbucket applicable with platform syntax adjustments)  
**Strategy:** Strict Separation of Concerns (Deterministic Gate vs. AI Feedback Pipeline)  
**Purpose:** Instructions and ready-to-use configuration files for automated AI agents and repository administrators.

---

## 1. Architectural Strategy & Role Division

To prevent notification fatigue, overlapping PR comments, and CI/CD bottlenecks, the 4 tools are strictly decoupled into two functional tiers:

```
                      Pull Request Created / Synchronized
                                      │
         ┌────────────────────────────┴────────────────────────────┐
         ▼                                                         ▼
[ Tier 1: Deterministic Quality & Security ]        [ Tier 2: AI Code Review & Test Feedback ]
   - Snyk Code (Security Gate)                         - CodeRabbit (Primary AI Code Reviewer)
   - SonarCloud (Quality Gate)                         - Qodo / PR-Agent (Unit Test & Integrity)
         │                                                         │
         ▼                                                         ▼
Status Checks (PASS / FAIL)                           Inline PR Comments & Summaries
(Blocks Merge if Vulnerabilities/Smells exist)        (Guides Developer, Suggests Improvements)
```

### Responsibility Matrix

| Tool | Assigned Tier | Execution Mode | PR Presentation | Merge Blocking? |
| :--- | :--- | :--- | :--- | :---: |
| **Snyk Code** | Tier 1 (Security) | GitHub Action / App Check | Status Check only (Quiet mode) | **YES (Required)** |
| **SonarCloud** | Tier 1 (Quality) | GitHub Action / App Check | Quality Gate status | **YES (Required)** |
| **CodeRabbit** | Tier 2 (AI Review) | GitHub App Webhook | PR Summary + Inline Logic Reviews | NO (Advisory) |
| **Qodo (PR-Agent)** | Tier 2 (Testing) | GitHub App / On-demand | Test Suite Generation (`/test`, `/improve`) | NO (Advisory) |

---

## 2. Tier 1 Configuration: Deterministic Security & Quality Gates

### 2.1 SonarCloud Configuration (`sonar-project.properties`)
Create this file at the repository root. Ensure scanning exclusions prevent analyzing generated artifacts, vendors, or test mocks.

```properties
# File: sonar-project.properties
sonar.projectKey=YOUR_ORGANIZATION_KEY_PROJECT_KEY
sonar.organization=YOUR_ORGANIZATION_KEY

# Source code analysis
sonar.sources=.
sonar.exclusions=**/node_modules/**,**/dist/**,**/build/**,**/bin/**,**/*.designer.cs,**/Tests/work/**,**/*.min.js

# Test definitions
sonar.tests=.
sonar.test.inclusions=**/*.spec.ts,**/*.test.js,**/*Test*.ps1,**/Tests/**

# Encodings & Language settings
sonar.sourceEncoding=UTF-8

# Quality Gate Threshold Rules (Configured in SonarCloud UI):
# - 0 New Bugs
# - 0 New Vulnerabilities
# - 0 New Security Hotspots
# - Coverage on New Code >= 80% (Optional based on team maturity)
```

---

### 2.2 GitHub Actions Pipeline (`.github/workflows/tier1-quality-security-gate.yml`)
Run Snyk and SonarCloud concurrently in parallel jobs. Both run in non-interactive / status-check mode to avoid PR comment spam.

```yaml
# File: .github/workflows/tier1-quality-security-gate.yml
name: "Tier 1: Security & Quality Gate"

on:
  pull_request:
    branches: [ main, develop ]
  push:
    branches: [ main ]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  snyk-code-security:
    name: "Snyk Code Security Scan"
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Run Snyk Code Scan (Fail on High/Critical)
        uses: snyk/actions/setup@master
      - name: Execute Snyk SAST
        env:
          SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
        run: |
          snyk code test --severity-threshold=high

  sonarcloud-analysis:
    name: "SonarCloud Quality Gate"
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code with Full History
        uses: actions/checkout@v4
        with:
          fetch-depth: 0 # Full history required for Sonar blameline analysis

      - name: SonarCloud Scan
        uses: SonarSource/sonarcloud-github-action@master
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
```

---

## 3. Tier 2 Configuration: AI Code Review & Feedback

### 3.1 CodeRabbit Configuration (`.coderabbit.yaml`)
CodeRabbit acts as the primary AI Reviewer (Senior Developer persona). It provides high-level executive summaries and inline logic critiques while refraining from duplicating linter rules already handled by SonarCloud.

```yaml
# File: .coderabbit.yaml
version: 2
language: "en-US" # or "th-TH"

early_access: false

reviews:
  # Review profile: chill | assertive (use chill to avoid noise)
  profile: "chill"
  
  # Do not automatically block PRs; human engineers make merge decisions
  request_changes_workflow: false
  
  # High-level summary of the pull request
  high_level_summary: true
  poem: false # Disable non-productive bot flavor
  
  # Tone and behavioral instruction
  instructions: |
    - Focus exclusively on: Business Logic correctness, Concurrency/Race conditions, Resource leaks, Edge cases, and Invariant enforcement.
    - DO NOT comment on formatting, styling, trivial linting, or standard security vulnerabilities handled by SonarCloud and Snyk.
    - If reviewing PowerShell, ensure StrictMode compatibility, UTF-8 BOM encoding for non-ASCII, and exact integer division behavior (-shr vs /).

  auto_review:
    enabled: true
    drafts: false # Skip work-in-progress PRs
    
  tools:
    ast-grep:
      enabled: false # Leave AST parsing to SonarCloud

chat:
  auto_reply: true # Allows developers to reply to comments to request code refactoring
```

---

### 3.2 Qodo / PR-Agent Configuration (`.pr_agent.toml`)
Qodo specializes in Test Generation, Edge-Case Synthesis, and Test Coverage Integrity. It is configured to run silently on standard PR creation, waiting for explicit slash-commands or focusing purely on tests.

```toml
# File: .pr_agent.toml
[pr_reviewer]
# Disable general code review to prevent overlapping with CodeRabbit
enable_review_labels_effort = false
num_code_suggestions = 1
inline_code_comments = false

[pr_description]
# Leave PR description generation to CodeRabbit
publish_description_as_comment = false

[pr_test]
# Focus Qodo on automatic test suite generation and test suggestions
enable_auto_generate_tests = true
num_tests = 4
testing_framework = "auto" # Automatically detects Pester, Jest, PyTest, etc.

[config]
# Output verbosity (0 = quiet, 1 = normal, 2 = verbose)
verbosity_level = 0
# Allows triggering Qodo on demand by commenting: /test or /improve
enable_command_triggers = true
```

---

## 4. GitHub Branch Protection Policy (The Merge Shield)

To enforce this setup in your repository, configure GitHub Branch Protection Rules on the target branch (e.g., `main`):

1. Navigate to: **Settings** -> **Branches** -> **Branch protection rules** -> Add rule for `main`.
2. Check: **"Require a pull request before merging"**
   - Check: *"Require approvals"* (Minimum: 1 human engineer)
   - Check: *"Dismiss stale pull request approvals when new commits are pushed"*
3. Check: **"Require status checks to pass before merging"**
   - In the search bar, require only Tier 1 checks:
     - ✅ `SonarCloud Quality Gate`
     - ✅ `Snyk Code Security Scan`
   - **DO NOT** make CodeRabbit or Qodo required status checks (prevents blocking merges when AI services experience transient latency or subjective disagreements).
4. Check: **"Require conversation resolution before merging"**
   - Ensures all discussions raised by CodeRabbit/Qodo or human reviewers are explicitly acknowledged and marked resolved.

---

## 5. Daily Developer Workflow Example

1. **Developer opens a PR:**
   - **Tier 1 (Instant):** Snyk and SonarCloud run in GitHub Actions. If a critical vulnerability or blocker code smell is found, the PR is automatically blocked with a red cross.
   - **Tier 2 (AI Summary):** CodeRabbit posts a 3-bullet summary of changes and inline suggestions on business logic flaws.
2. **Developer requests unit tests:**
   - The developer comments `/test` on the PR.
   - **Qodo** generates complementary unit test cases covering edge cases identified in the diff.
3. **Developer fixes issues & pushes updates:**
   - Tier 1 checks re-run automatically.
   - Once Snyk & SonarCloud turn green and CodeRabbit suggestions are resolved, the team merges with 100% confidence.
