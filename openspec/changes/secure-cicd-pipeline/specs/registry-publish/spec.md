# Spec Delta: registry-publish

## Purpose

Tags the built image with a semantic version and the `latest` label and publishes it to the configured GCP Artifact Registry repository using Workload Identity Federation, never static long-lived credentials.

## ADDED Requirements

### Requirement: Semantic and latest tagging
The pipeline SHALL tag the built image with both a semantic version (e.g. `v1.0.1`) and `latest` before publishing. The semantic version SHALL be sourced from a valid git tag (`vX.Y.Z`) on the commit being published. The `latest` tag is a mutable pointer to the most recently published version.

#### Scenario: Image tagged with version and latest
- **WHEN** the publish step prepares the image
- **THEN** the local image carries the semver tag and the `latest` tag
- **AND** both tags point to the same built image local digest

#### Scenario: Semantic version from git tag
- **WHEN** the publish step resolves the version
- **THEN** the semver tag is derived from the git tag on the current commit matching the `vX.Y.Z` pattern

#### Scenario: Missing valid git tag blocks publish
- **WHEN** the current commit has no git tag matching the semver pattern
- **THEN** the publish stage exits with a non-zero status
- **AND** no image is pushed to the registry

### Requirement: Publish to GCP Artifact Registry
The pipeline SHALL push the tagged image to the configured GCP Artifact Registry repository so that it is pullable from that registry. Publishing SHALL use Workload Identity Federation credentials and SHALL NOT embed static registry credentials in the image or pipeline.

#### Scenario: Image published to registry
- **WHEN** the publish step runs with valid Workload Identity credentials
- **THEN** the image (semver and latest tags) is pushed to the configured Artifact Registry repository
- **AND** no static username/password credentials appear in the image, the pipeline definition, or logs

#### Scenario: Publish with unreachable registry
- **WHEN** the registry repository is unreachable or credentials are invalid
- **THEN** the publish stage exits with a non-zero status
- **AND** the image is not marked as published