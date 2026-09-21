# Spec Delta: cicd-pipeline

## Purpose

Defines the declarative CI/CD pipeline that orchestrates the full lifecycle: checkout, lint and unit tests, multi-stage image build, vulnerability scan, and registry publish, with each stage guarded by its own validation.

## ADDED Requirements

### Requirement: Declarative pipeline stages
The pipeline SHALL be expressed declaratively with distinct, ordered stages for: code validation (lint and unit tests), container build, security scan, and publish to the registry. Each stage SHALL run only if its declared dependencies ran successfully.

#### Scenario: Pipeline runs all stages in order on success
- **WHEN** the full pipeline is triggered on a valid commit
- **THEN** stages execute in the declared sequence
- **AND** the pipeline overall status is success

#### Scenario: Stage failure halts the pipeline
- **WHEN** any stage fails (lint, tests, build, scan, or publish)
- **THEN** the pipeline stops execution at that stage
- **AND** the overall pipeline status is failure

### Requirement: Code quality gates
The pipeline SHALL run Python linting (flake8) and unit tests (pytest) as part of the code validation stage. The pipeline SHALL fail if linting errors or failing tests are present.

#### Scenario: Lint errors fail the pipeline
- **WHEN** the validation stage detects flake8 errors
- **THEN** the validation stage exits with a non-zero status
- **AND** the overall pipeline is marked as failed

#### Scenario: Failing tests fail the pipeline
- **WHEN** the validation stage runs pytest and one or more tests fail
- **THEN** the validation stage exits with a non-zero status
- **AND** the overall pipeline is marked as failed

### Requirement: No secrets in pipeline
The pipeline SHALL NOT store or log secret values. Credentials for registry publication SHALL come from the CI provider's secret store / Workload Identity; LLM API keys SHALL be injected only at application runtime.

#### Scenario: Secrets remain external
- **WHEN** the pipeline executes end to end
- **THEN** no secret value (LLM key, registry credential) is written to pipeline logs or to the built image

### Requirement: Build traceability
The pipeline SHALL record, as a build artifact, metadata linking a run to its origin: the git commit SHA, the build trigger/URL, and the image digest(es) produced. Reports and published artifacts SHALL reference this build metadata.

#### Scenario: Build metadata recorded
- **WHEN** a pipeline run completes
- **THEN** a build metadata artifact exists containing the git commit SHA and the build URL
- **AND** any image digest produced by that run is recorded in the metadata