# PrintGateway DevSecOps and AI Review Best Practice

Last verified: 2026-09-26

## 1. Architecture

PrintGateway separates deterministic merge gates from advisory AI reviews.

### Tier 1 — Required deterministic checks

| Check | Purpose | Blocks merge |
|---|---|---:|
| PrintGateway Safe Regression | Runs the repository's eight safe regression cases without connecting to a printer | Yes |
| PowerShell Static Analysis | Runs security-focused PSScriptAnalyzer rules against PowerShell source | Yes |
| SonarQube Cloud Scan | Submits supported files, waits for the server-side Quality Gate, and fails when the gate is red | Yes |

SonarQube Cloud may also publish `SonarCloud Code Analysis`. Treat that status
as additional evidence, not as a required check, because it may not be generated
for a pull request from a fork.

### Tier 2 — Advisory AI review

| Tool | Purpose | Blocks merge |
|---|---|---:|
| Qodo | Provides advisory PR summaries and code-review findings | No |

AI-generated findings must be reviewed by a human. Qodo must not be configured
as a required status check.

## 2. Platform constraints

Snyk Code is not used as a merge gate because its supported-language list
does not include PowerShell.

SonarQube Cloud does not provide full PowerShell source-code analysis.
It remains useful for supported files, GitHub Actions, YAML, secrets, and
server-side Quality Gate enforcement.

PowerShell source analysis is performed by the open-source
PSScriptAnalyzer module.

The repository's tests are custom PowerShell regression scripts, not Pester
tests. The CI entrypoint is:

`Tests/Invoke-PrintGatewayTests.ps1`

Hardware printing is excluded from automated CI. Real-printer tests require
explicit human execution and must never run automatically on a GitHub-hosted
runner.

## 3. Repository configuration

The authoritative configuration files are:

- `.github/workflows/tier1-quality-security-gate.yml`
- `sonar-project.properties`
- `.pr_agent.toml`

Do not duplicate the complete GitHub Actions workflow in this document.
The workflow file is the authoritative implementation.

All third-party GitHub Actions must be pinned to full commit SHAs.

## 4. GitHub secrets

The workflow requires:

- `SONAR_TOKEN`

GitHub does not expose repository secrets to pull requests from forks. The
workflow therefore skips the SonarQube Cloud scan for fork pull requests without
exposing the token; the PowerShell static-analysis and safe-regression gates
continue to run. Do not use `pull_request_target` to execute fork code with
repository secrets.

A `SNYK_TOKEN` is not required by the current architecture.

Never commit tokens, credentials, production databases, printer addresses,
operational logs, or files generated under `Tests/work/`.

## 5. GitHub ruleset

Activate the `main` branch ruleset only after all current checks have
completed successfully.

Require these status checks:

- `PrintGateway Safe Regression`
- `PowerShell Static Analysis`
- `SonarQube Cloud Scan`

Do not require:

- Qodo
- SonarCloud Code Analysis
- Snyk Code Security Scan
- obsolete Pester check names

Recommended protections:

- Require a pull request before merging.
- Require all selected status checks to pass.
- Require conversation resolution.
- Block force pushes.
- Block branch deletion.
- Do not require a human approval when the repository has only one maintainer.
  Change this to one approval when an independent reviewer is available.

## 6. Pull-request workflow

1. Create a feature branch.
2. Open a pull request into `main`.
3. Wait for all Tier 1 checks.
4. Fix deterministic failures rather than bypassing them.
5. Review AI suggestions as advisory evidence.
6. Resolve applicable review conversations.
7. Merge only when every required Tier 1 check is green.

Qodo repository-level configuration becomes effective after it is merged
into the default branch. Validate it using a subsequent test pull request.

## 7. Cost and licensing

The selected workflow uses GitHub Actions allowances for public repositories,
SonarQube Cloud's open-source/public-project offering, PSScriptAnalyzer, and
Qodo's available public-repository integration.

No additional paid SAST service is required for the current PowerShell-only
codebase. Service terms and public-project limits may change and should be
rechecked periodically.

## 8. References

- Snyk supported languages:
  https://docs.snyk.io/supported-languages/supported-languages-package-managers-and-frameworks
- SonarQube Cloud supported languages:
  https://docs.sonarsource.com/sonarqube-cloud/analyzing-source-code/languages
- PSScriptAnalyzer:
  https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/overview
- Qodo repository configuration:
  https://docs.qodo.ai/qodo-documentation/code-review/get-started/configuration-overview/configuration-file
