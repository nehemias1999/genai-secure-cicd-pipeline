# Spec Delta: container

## Purpose

Defines how the application is packaged into a minimal, hardened container image built through a multi-stage Docker build ending in a non-root runtime stage.

## ADDED Requirements

### Requirement: Multi-stage build
The image SHALL be produced by a multi-stage Docker build: a full build stage that installs dependencies and a final lightweight runtime stage that copies only the necessary artifacts. The final image SHALL contain a Python runtime with the API application and its runtime dependencies only.

#### Scenario: Build stage produces slim runtime image
- **WHEN** the image is built from the multi-stage Dockerfile
- **THEN** the final image contains only the Python runtime, the application, and runtime dependencies
- **AND** package caches and build tooling from the build stage are not present in the final image

### Requirement: Non-root execution
The final image SHALL create and run as a non-root user. The process SHALL NOT run as root (`UID 0`).

#### Scenario: Image runs as non-root user
- **WHEN** a container is started from the final image
- **THEN** the main process runs as a non-root user
- **AND** the user is an unprivileged user created during the image build

### Requirement: Runtime dependencies pinned
Runtime dependencies SHALL be declared and pinned so that builds are reproducible. Development-only dependencies (test, lint) SHALL NOT be present in the final image.

#### Scenario: Reproducible runtime environment
- **WHEN** the image is built twice from the same commit
- **THEN** the resulting runtime dependency set is identical
- **AND** dev-only packages such as pytest and flake8 are not installed in the final image

### Requirement: OCI provenance labels
The final image SHALL carry OCI provenance labels recording the source revision (git commit SHA), the source repository URL, and the build timestamp, so each artifact is traceable to its origin.

#### Scenario: Image exposes provenance labels
- **WHEN** the final image is inspected with `docker inspect`
- **THEN** OCI labels for source revision, source repository, and build timestamp are present
- **AND** the revision label matches the git commit that triggered the build