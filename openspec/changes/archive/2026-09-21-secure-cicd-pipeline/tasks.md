# Tasks

## 1. Scaffolding (repo hygiene)

- [ ] 1.1 Add `.gitignore` (Python, Docker, reports/, .env) and verify `git status` is clean of stray artifacts
- [ ] 1.2 Add `requirements.txt` with pinned runtime deps (fastapi, uvicorn) and verify `pip install -r requirements.txt` resolves or a lockfile can be produced
- [ ] 1.3 Add `requirements-dev.txt` (pytest, flake8, httpx) and verify dev tooling installs

## 2. API (`api`)

- [ ] 2.1 Implement `src/main.py` FastAPI app: `GET /health` returns 200 with status JSON, no auth, and verify `pytest tests/test_api.py::test_health` passes (RED→GREEN)
- [ ] 2.2 Implement `POST /generate` accepting JSON `{prompt}` returning simulated LLM response, and verify `pytest tests/test_api.py::test_generate` passes
- [ ] 2.3 Return `422` when `prompt` missing (also empty and oversized), read LLM key from env `GEMINI_API_KEY` at runtime, and verify tests for `422` and key-not-embedded-in-image behavior pass
- [ ] 2.4 Return structured JSON errors (`code`, `message`) on client and unexpected failures, keep process alive on internal error, and verify tests assert error shape + `/health` still succeeds after a forced failure

## 3. Container (`container`)

- [ ] 3.1 Write multi-stage `Dockerfile` (builder `python:3.12-slim` installs pinned deps; runtime copies app + site-packages, non-root user) and verify `docker build` succeeds
- [ ] 3.2 Add `.dockerignore`, run image entrypoint as non-root, and verify `docker run` reports non-root UID and image has no dev packages (`pip list` check)
- [ ] 3.3 Verify final image does not contain pytest/flake8 or build cache (`docker run ... pip list`) as a reproducibility sanity check
- [ ] 3.4 Add OCI provenance labels (source revision, source repo, timestamp) to the final image stage, and verify `docker inspect` shows the labels

## 4. Security scan (`security-scan`)

- [ ] 4.1 Add `scripts/run-trivy.sh` scanning the local image with JSON + HTML reports under `reports/`, and verify `bash -n scripts/run-trivy.sh` and a trivy run against a local test image succeeds
- [ ] 4.2 Enforce severity gate: exit 1 on CRITICAL/HIGH (configurable), and verify a run against an image known to be clean exits 0
- [ ] 4.3 Persist reports to `reports/` and verify JSON and HTML files are produced after a scan run
- [ ] 4.4 Record scanned image digest + git commit SHA in the report, and add non-blocking `trivy fs` repo scan; verify report contains digest/commit and fs findings don't fail the pipeline

## 5. Registry publish (`registry-publish`)

- [ ] 5.1 Add `scripts/publish.sh`: resolves semver from git tag (`vX.Y.Z` required) and `latest`, verifies both tags point to same local digest, and `bash -n scripts/publish.sh` passes
- [ ] 5.2 Implement `gcloud` Workload Identity credential handling (env-driven, `--cred-file`) and `docker push` to `$REGION-docker.pkg.dev/$PROJECT/$REPO/$IMAGE`, and verify publish is skipped cleanly (exit non-zero with clear message) when no valid git tag OR registry env vars are unset (safe local dry-run)
- [ ] 5.3 Verify no static credentials are embedded (grep for GCP_SA_KEY/JSON key patterns in repo) — gate of secrets

## 6. CI/CD pipeline (`cicd-pipeline`)

- [ ] 6.1 Write declarative `Jenkinsfile` with stages Checkout & Lint → Build → Security Scan → Publish, and verify syntax via `act`-equivalent lint or declarative lint where available
- [ ] 6.2 Verify `openspec validate` passes and all stages fail-fast in declared order (stage-failure halts pipeline)
- [ ] 6.3 Add build traceability: metadata artifact with commit SHA + build URL + produced digests; and verify no secrets in pipeline files (grep for key patterns) — final secrets gate

## 7. Final integration

- [ ] 7.1 Run full local loop: pytest → flake8 → docker build → trivy → (dry) publish, and verify all gates pass with evidence
- [ ] 7.2 Update README with pipeline architecture, stage summary, and operator setup (GCP env vars, Workload Identity) notes