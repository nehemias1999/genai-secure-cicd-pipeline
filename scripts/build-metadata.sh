#!/usr/bin/env bash
# ==============================================================================
# Description: Generates the build traceability artifact (build-metadata.json):
#   commit SHA, build URL, image and produced digest. The authoritative digest
#   comes from the scan JSON report (ScanTrace.imageDigest enriched by
#   scripts/run-trivy.sh); if the scan hasn't run yet, falls back to the local
#   container runtime digest (RepoDigests[0] or Id), same as run-trivy.sh. Outside
#   Jenkins (no BUILD_URL) the buildUrl field is emitted empty: the artifact is
#   equally valid for local traceability.
# Author: implementer-req5 (SDD flow, requirement cicd-pipeline)
# Usage: ./scripts/build-metadata.sh <IMAGE> [OUTDIR]
#   IMAGE   (required) local image tag, e.g., genai-secure-api:latest
#   OUTDIR  (optional, default reports/) output directory for the artifact
#   -h|--help prints help to STDOUT and exits 0
# Env Vars:
#   GIT_COMMIT  checkout commit (provided by Jenkins); if absent uses git rev-parse
#   BUILD_URL   build URL (provided by Jenkins); if absent field is emitted empty
#   CTR_CMD     container runtime (default: docker if exists, else podman)
# Dependencies: jq, git, docker (or podman)
# Output:
#   $OUTDIR/build-metadata.json  JSON {commitSha, buildUrl, image, imageDigest, buildTimestamp}
#   stdout: path of generated artifact; stderr: errors and warnings
# Exit codes:
#   0  artifact generated successfully
#   2  usage error: missing required arguments
#   3  infrastructure failure: jq missing or invalid JSON report
# ==============================================================================
set -Eeuo pipefail

usage() { # prints help; $1 = destination fd (1 stdout for --help, 2 for usage error)
  local text="Usage: $(basename "$0") <IMAGE> [OUTDIR]
  IMAGE       local image to register in metadata (required)
  OUTDIR      output directory for artifact (default: reports/)
Options:
  -h, --help  shows this help and exits 0
Env: GIT_COMMIT, BUILD_URL, CTR_CMD"
  if [[ "${1:-1}" == "2" ]]; then
    printf '%s\n' "$text" >&2
  else
    printf '%s\n' "$text"
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage 1
  exit 0
fi

if [[ "$#" -lt 1 ]]; then
  usage 2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq not found in PATH (required dependency)\n' >&2
  exit 3
fi

IMAGE="$1"
OUTDIR="${2:-reports/}"
mkdir -p "$OUTDIR"

# Commit: GIT_COMMIT provided by Jenkins checkout; locally falls back to repo HEAD
COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD 2>/dev/null || printf 'unknown\n')}"
COMMIT="${COMMIT:-unknown}"
BUILD_URL="${BUILD_URL:-}"
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Authoritative digest: ScanTrace from trivy JSON report (enriched by
# scripts/run-trivy.sh). If scan hasn't run yet, falls back to local digest.
SCAN_REPORT="${OUTDIR%/}/trivy-image.json"
DIGEST=""
if [[ -f "$SCAN_REPORT" ]]; then
  DIGEST="$(jq -r '.ScanTrace.imageDigest // empty' "$SCAN_REPORT" 2>/dev/null || printf '')"
fi
if [[ -z "$DIGEST" ]]; then
  CTR_CMD="${CTR_CMD:-}"
  if [[ -z "$CTR_CMD" ]]; then
    if command -v docker >/dev/null 2>&1; then
      CTR_CMD="docker"
    else
      CTR_CMD="podman"
    fi
  fi
  DIGEST="$("$CTR_CMD" image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || printf '')"
  if [[ "$DIGEST" != *"@sha256:"* ]]; then
    DIGEST="$("$CTR_CMD" image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || printf 'unknown\n')"
  else
    DIGEST="${DIGEST##*@}"
  fi
fi
DIGEST="${DIGEST:-unknown}"

jq -n \
  --arg commitSha "$COMMIT" \
  --arg buildUrl "$BUILD_URL" \
  --arg image "$IMAGE" \
  --arg imageDigest "$DIGEST" \
  --arg buildTimestamp "$BUILD_TIMESTAMP" \
  '{commitSha: $commitSha, buildUrl: $buildUrl, image: $image, imageDigest: $imageDigest, buildTimestamp: $buildTimestamp}' \
  > "$OUTDIR/build-metadata.json" || {
    printf 'error: jq failed to generate build-metadata.json\n' >&2
    exit 3
  }

printf 'metadata: %s (commit=%s image=%s digest=%s)\n' "$OUTDIR/build-metadata.json" "$COMMIT" "$IMAGE" "$DIGEST"
exit 0