# PrintGateway DevSecOps Agent Directive

**Document role:** Mandatory instructions for AI agents and automation tools  
**Authoritative guide:** `DEVSECOPS_AI_INTEGRATION_BEST_PRACTICE.md`  
**Authoritative implementation:** `.github/workflows/tier1-quality-security-gate.yml`

## 1. Purpose

This document defines the mandatory operating rules for any implementation,
review, or audit agent working on the PrintGateway DevSecOps configuration.

The agent must base decisions on the repository's current files and actual
check results. Historical examples, previous bot comments, and outdated
documentation must not override the current implementation.

Do not duplicate the complete GitHub Actions workflow in this document. The
workflow file is the source of truth.

## 2. Operating mode

Begin every assessment in read-only mode.

Before changing repository files or GitHub settings:

1. Inspect the current branch and working tree.
2. Identify existing user changes and preserve unrelated work.
3. Inspect the current workflow and its pinned dependencies.
4. Inspect the real test entrypoints.
5. Inspect the latest GitHub Actions and SonarQube Cloud results.
6. Report findings with exact file, check, or log evidence.
7. Separate confirmed facts from assumptions and recommendations.

Repository files or external settings may be changed only when the user
explicitly requests implementation.

## 3. Deterministic merge gates

The required deterministic checks are:

- `PrintGateway Safe Regression`
- `PowerShell Static Analysis`
- `SonarQube Cloud Scan`

`SonarQube Cloud Scan` waits for the server-side Quality Gate and fails when
that gate is red. The provider-generated `SonarCloud Code Analysis` status is
additional evidence when present, but it is not a required check because it may
not be created for pull requests from forks.

A deterministic failure must be fixed at its source.

The agent must not:

- Add `continue-on-error` to hide a failure.
- Disable a rule solely to make CI pass.
- Delete or skip a failing test without technical justification.
- Weaken the SonarQube Cloud Quality Gate to obtain a green result.
- Treat a successful scanner submission as proof that the server-side Quality
  Gate passed.
- Replace a deterministic check with an AI-generated opinion.

## 4. Safe regression testing

The authoritative CI test entrypoint is:

`Tests/Invoke-PrintGatewayTests.ps1`

The safe suite currently executes eight regression cases through:

`Tests/PrintGateway.Tests.ps1`

The CI test environment must use a Windows runner because the repository
contains Windows-specific PowerShell behavior and `System.Drawing`
dependencies.

Automated CI must never:

- Connect to a real printer.
- Send ESC/POS print data.
- Depend on a printer being online.
- Run hardware tests without explicit human authorization.
- Treat a TCP connection as proof of a successful printer-status response.

Real-hardware printing and fault-state verification must remain separate from
automated safe regression tests.

## 5. PowerShell security analysis

Use the open-source PSScriptAnalyzer module for deterministic PowerShell source
analysis.

PSScriptAnalyzer must run with an explicitly pinned module version. Blocking
rules must be listed explicitly so future module updates cannot silently alter
the merge policy.

Snyk Code must not be introduced as the PowerShell merge gate because its
supported-language list does not include PowerShell.

SonarQube Cloud must not be described as complete PowerShell SAST. Its role in
this repository is analysis of supported repository content, GitHub Actions,
YAML, secrets, and server-side Quality Gate enforcement.

## 6. SQLite transaction safety

SQLite operations that contain multiple dependent statements must fail closed.

When invoking the SQLite CLI:

- SQL must be supplied through standard input when fail-fast batch behavior is
  required.
- Use `-bail` so execution stops after the first SQL error.
- Check the process exit code.
- Treat a nonzero exit code as a failed operation.
- Do not allow a later `COMMIT` to execute after an earlier statement failed.
- Preserve atomic rollback behavior for state transitions and audit events.

Tests that intentionally force an audit failure must confirm that the associated
job-state change is rolled back.

SQLite path resolution must follow this priority:

1. Explicit `-SqlitePath` supplied by the caller.
2. `C:\PrintGateway\Bin\sqlite3.exe`.
3. `sqlite3.exe` available through `PATH`.
4. The local Android SDK fallback path.

Tests must account for the documented priority and must not assume that the
Android SDK path is always selected.

## 7. Supply-chain requirements

Every third-party GitHub Action must use a verified full commit SHA.

Do not use mutable references such as:

- `@master`
- `@main`
- Version-only references such as `@v7`

Retain the corresponding release version in an adjacent comment so maintainers
can understand and deliberately update the pinned dependency.

Before updating a pinned SHA:

1. Verify the upstream repository.
2. Verify the intended release or tag.
3. Resolve the full commit SHA from the upstream source.
4. Review relevant release notes and breaking changes.
5. Run all deterministic checks after the update.

## 8. SonarQube Cloud

The workflow job must wait for the server-side Quality Gate by using
`sonar.qualitygate.wait=true`. Therefore, a green `SonarQube Cloud Scan` job
confirms that the submitted analysis and its Quality Gate passed.

When the provider-generated `SonarCloud Code Analysis` status is present, the
agent must verify that it agrees with the workflow job. Its absence on a fork
pull request is not a failure because GitHub withholds `SONAR_TOKEN` from forked
code and the workflow deliberately skips that secret-dependent scan.

The repository requires `SONAR_TOKEN` as a GitHub Actions secret. Never print,
log, expose, or commit the token.

## 9. AI review tools

Qodo is advisory only.

They must not:

- Be configured as required status checks.
- Automatically decide whether a pull request may merge.
- Replace deterministic tests or static analysis.
- Duplicate routine findings already covered by PSScriptAnalyzer, safe
  regression tests, or SonarQube Cloud.
- Be treated as authoritative when their findings conflict with reproducible
  evidence.

AI findings require human evaluation before changes are accepted.

Repository-level Qodo configuration must be validated with a new pull request
after `.pr_agent.toml` has been merged into the default branch. The current
pull request must not be treated as proof that an unmerged Qodo configuration
has taken effect.

## 10. GitHub ruleset

Do not activate or modify the `main` ruleset until the required checks have
appeared and passed on a real pull request.

When explicitly authorized, configure the ruleset to:

- Target the `main` branch.
- Require a pull request before merging.
- Require all three deterministic checks.
- Require conversation resolution.
- Block force pushes.
- Block branch deletion.
- Exclude Qodo from required status checks.

For a repository with only one maintainer, do not require an unavailable
independent approval. Require at least one approval when an independent reviewer
is available.

Activate the ruleset only after the exact current check names are available for
selection.

## 11. Secret and repository safety

Never commit:

- API tokens or credentials.
- Production databases.
- Printer addresses or operational endpoints.
- Operational logs containing sensitive data.
- User-specific files or absolute personal paths.
- Generated files under `Tests/work/`.
- Temporary databases, raster output, or printer payload captures.

The current workflow requires `SONAR_TOKEN`. It does not require `SNYK_TOKEN`.

Before publishing or merging, inspect the complete changed-file list and verify
that no operational or personal artifacts are included.

## 12. Documentation requirements

Documentation must describe the implemented architecture rather than an
intended or historical design.

The agent must update documentation whenever any of the following changes:

- Required status-check names.
- Workflow job names.
- Static-analysis tools.
- Test entrypoints.
- GitHub Actions dependencies.
- Secret requirements.
- Ruleset requirements.
- AI-review behavior.

Do not retain obsolete examples that instruct maintainers to require Snyk,
Pester, or renamed Sonar checks.

## 13. Change protocol

For each implementation round:

1. Make the smallest coherent change.
2. Inspect the complete diff.
3. Run relevant local validation when available.
4. Commit with a specific description.
5. Push to the feature branch.
6. Wait for all checks to finish.
7. Read the actual failure log if a check fails.
8. Fix the underlying cause.
9. Do not merge while documentation, checks, or settings remain inconsistent.

A failed run must not be rerun unchanged when the failure is deterministic.
Create a corrective commit so the new run tests the corrected state.

## 14. Completion criteria

A PrintGateway DevSecOps implementation is complete only when:

1. `PrintGateway Safe Regression` passes.
2. `PowerShell Static Analysis` passes.
3. `SonarQube Cloud Scan` passes.
4. `SonarCloud Code Analysis` agrees when that provider status is generated.
5. Safe regression tests run without printer access.
6. Third-party GitHub Actions are pinned to full commit SHAs.
7. Documentation matches the implemented workflow.
8. Qodo remains non-blocking.
9. The `main` ruleset requires only current deterministic checks.
10. A follow-up pull request confirms the active ruleset and default-branch AI
    configuration behave as documented.

Until every applicable criterion is verified, the agent must report the work as
incomplete and must not recommend merging.
