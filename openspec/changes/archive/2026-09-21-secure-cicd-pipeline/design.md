# Design: secure-cicd-pipeline

## Context

See proposal.md — Why and What Changes. This is a greenfield DevSecOps showcase repository: a minimal FastAPI dummy GenAI API delivered through a secure, immutable CI/CD pipeline. No existing code, infra, or conventions to preserve.

## Goals / Non-Goals

**Goals**
- A reproducible local build and test loop: `pytest`, `flake8`, `docker build`, `trivy image` all runnable from a dev machine.
- A declarative Jenkins pipeline whose stages map 1:1 to the spec capabilities.
- Secrets stay out of the image and the pipeline: LLM key injected at app runtime; registry auth via Workload Identity Federation.

**Non-Goals**
- No real LLM provider integration — the API always returns a simulated response.
- No real cloud publishing automation from this repo's CI until a human approves registry access (this repo runs on GitHub; registry credentials belong to the operator's GCP project).
- No k8s deployment, no IaC for the Artifact Registry repository (out of scope here; GCP setup documented as operator steps).

## Decisions

**D1. FastAPI + uvicorn over Flask**
Selected over Flask because the spec's API contract (typed request body, automatic `422` on missing field) is native FastAPI behavior (Pydantic), keeping the API code tiny. Verification: pytest asserts on `/health`, `/generate` and the `422` missing-prompt case.

**D2. Multi-stage Dockerfile: `python:3.12-slim` builder → `python:3.12-slim` runtime**
A full build stage installs pinned runtime deps; the final stage copies only `src/` and installed site-packages, adds a non-root user, and runs `python -m uvicorn`. Keeps runtime small and Trivy's surface minimal. Dev deps (pytest, flake8) are only in the builder/CI layer, never the final image.

**D3. Trivy local-image scan + fail-on-critical/high**
`trivy image --format json` and `--format template --template "@html.tmpl"` run against the locally built image (no push needed), with `--severity CRITICAL,HIGH --exit-code 1`. Reports written to `reports/` and archived. Lower severities recorded but non-fatal.

**D4. GCP Artifact Registry publish via Workload Identity Federation**
`scripts/publish.sh` uses the federated OIDC credentials provided by the CI secret store to run `gcloud auth login --cred-file`, then `docker push` to `$REGION-docker.pkg.dev/$PROJECT/$REPO/$IMAGE`. Tags: semver + `latest`. No `GCP_SA_KEY` static JSON in the image or pipeline (`secrets-management`). The specific project/repo/region come from operator-supplied environment variables, not hardcoded secrets.

**D5. Scripts over inline Jenkins stage code**
All non-trivial logic lives in `scripts/` (bash) so the Jenkinsfile stays declarative and thin, and the same logic is testable/runnable locally (`pipeline` profile: `bash -n` syntax check, shellcheck if present).

## Risks / Trade-offs

- [Trivy unknown/missing DB on offline Jenkins] → Pin `aquasec/trivy:latest` image or use the `db` mirror; document `TRIVY_*` overrides.
- [Workload Identity setup is operator-side (GCP)] → Publish stage reads env vars and fails clearly with a message when credentials are not provisioned; never guesses.
- [Semver source] → Tag derives from env `IMAGE_TAG` (operator sets to `vX.Y.Z`); defaults to a generated timestamp tag, never false `vMAJOR.MINOR.PATCH`.
- [Simulated API is not a real LLM call] → `/generate` returns a deterministic mock; documented as such; a real provider can be swapped behind the same env-var contract later.

## Migration Plan

1. Implement per-requirement (see tasks.md), PR per requirement into `main`.
2. Local verification per requirement: pytest/flake8, docker build, trivy run, shell syntax.
3. Cloud publish is only exercised by the operator's Jenkins (or manually with their GCP) — never `terraform apply`-style real actions from this repo's CI without human approval.

## Open Questions

None — any GCP project/repo/region specifics belong to the operator environment, not this repo. If they change, they change env vars, not specs or design.