# Spec Delta: security-scan

## Purpose

Scans the built container image for known vulnerabilities using Trivy, generates JSON and HTML reports, and breaks the pipeline when findings exceed the allowed severity threshold.

## ADDED Requirements

### Requirement: Trivy image scan
The pipeline SHALL run a Trivy vulnerability scan against the locally built image as part of the CI/CD flow, without requiring registry push first.

#### Scenario: Scan reports vulnerabilities
- **WHEN** the scanning step runs against the built image
- **THEN** Trivy completes and lists detected vulnerabilities with their severities
- **AND** the scan runs against the locally built image, not a registry copy

### Requirement: Severity gate
The pipeline SHALL fail when the scan finds vulnerabilities at or above the configured severity threshold (critical/high) in the final image. Vulnerabilities at lower severities SHALL be reported but SHALL NOT fail the build.

#### Scenario: Critical vulnerability fails the pipeline
- **WHEN** the scan detects a critical or high severity vulnerability in the image
- **THEN** the pipeline stage exits with a non-zero status
- **AND** the overall pipeline is marked as failed

#### Scenario: Only low-severity findings
- **WHEN** the scan detects only low or medium severity vulnerabilities
- **THEN** the warnings are recorded in the report
- **AND** the pipeline continues successfully

### Requirement: Vulnerability reports
The pipeline SHALL persist vulnerability reports in JSON and HTML formats as build artifacts for observability. Each report SHALL record the scanned image digest and the source commit that produced it, so findings are traceable to a specific artifact.

#### Scenario: Reports are generated
- **WHEN** the scanning stage completes
- **THEN** a JSON report and an HTML report of the vulnerabilities are available as pipeline artifacts

#### Scenario: Reports are traceable
- **WHEN** a scan report is produced
- **THEN** the report records the scanned image digest and the git commit SHA of the build that produced it

### Requirement: Source and config scan
The pipeline SHALL also run a Trivy filesystem scan (e.g. `trivy fs`) over the repository source and configuration to detect misconfigurations and vulnerabilities in code/config, as a non-blocking gate.

#### Scenario: Filesystem scan runs without blocking
- **WHEN** the security stage runs
- **THEN** a filesystem scan of the repository is executed
- **AND** its findings are reported but do not fail the pipeline by themselves