# Proposal: secure-cicd-pipeline

## Why

The repository currently holds an application idea but no implementation of a secure, end-to-end CI/CD pipeline. This change builds a production-grade DevSecOps showcase: a minimal FastAPI GenAI-backed REST API delivered through a shift-left, immutable container pipeline that scans images for vulnerabilities before they reach any registry.

## What Changes

- Add a minimal FastAPI dummy GenAI REST API (`/health`, `/generate`) that simulates interacting with an LLM and reads the provider API key from runtime environment variables (never baked into the image).
- Add a multi-stage `Dockerfile` that produces a small, hardened runtime image running as a non-root user, plus a `.dockerignore`.
- Add `flake8` linting and `pytest` unit tests wired as pipeline gates.
- Add `scripts/run-trivy.sh` to scan the built image and break the pipeline on critical/high-severity vulnerabilities, emitting JSON and HTML reports.
- Add a declarative Jenkins pipeline (`Jenkinsfile`) with stages: Checkout & Lint → Build → Security Scan → Publish.
- Add `scripts/publish.sh` to tag (semver + `latest`) and push the image to GCP Artifact Registry using Workload Identity Federation, without static credentials.
- Wire `tests/`, `requirements.txt`, and workspace hygiene files (`.gitignore`).

## Capabilities

### New Capabilities
- `api`: Minimal FastAPI dummy GenAI REST API with health and generate endpoints, runtime-injected LLM credentials.
- `container`: Multi-stage Docker build producing a minimal, hardened, non-root runtime image.
- `security-scan`: Trivy vulnerability scanning of the built image with fail-on-critical gating and JSON/HTML reports.
- `registry-publish`: Semantic tagging and publishing of the image to GCP Artifact Registry via Workload Identity.
- `cicd-pipeline`: Declarative Jenkins pipeline orchestrating lint, build, scan, and publish stages with per-stage validation.

### Modified Capabilities
None (greenfield repository).

## Impact

- **Code**: `src/main.py`, `tests/`, `requirements.txt`.
- **Infrastructure/CI**: `Jenkinsfile`, `scripts/run-trivy.sh`, `scripts/publish.sh`, `Dockerfile`, `.dockerignore`.
- **Cloud**: GCP Artifact Registry repository (Workload Identity Federation pool for authentication; provider account grants are out of repo scope and configured by the operator).
- **Dependencies**: Python (FastAPI, uvicorn), pytest, flake8; Trivy; Jenkins; GCP Artifact Registry.