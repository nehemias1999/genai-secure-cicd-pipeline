#!/usr/bin/env bash
# ==============================================================================
# Description: Tags the local image with semver ($IMAGE:vX.Y.Z) and latest and
#   publishes to GCP Artifact Registry via Workload Identity Federation (never
#   static credentials). The semver version is resolved from the GIT_TAG env or
#   the exact git tag of the current commit (pattern vX.Y.Z). The --dry-run mode
#   validates all logic locally (resolution, local tags, digest checksum) without
#   touching the network or registries.
# Author: implementer-req4 (SDD flow, requirement registry-publish)
# Usage: IMAGE=<name> [SOURCE_TAG=<tag>] scripts/publish.sh [--dry-run]
#   --dry-run  validates resolution + local tags + digest and stops before push
#              (no network); useful without real GCP credentials
#   -h|--help  prints help to STDOUT and exits 0
# Env Vars:
#   IMAGE           (required) image name WITHOUT tag, e.g., genai-secure-api
#   SOURCE_TAG      local source tag of the build (default: latest), e.g., req4-test
#   REGION          Artifact Registry region, e.g., us-central1 (required)
#   PROJECT_ID      GCP project (required)
#   REGISTRY_REPO   Artifact Registry repository (required)
#   GIT_TAG         semver tag vX.Y.Z (optional; default: git describe --tags --exact-match)
#   GOOGLE_APPLICATION_CREDENTIALS / CI_IAM_CREDENTIALS_FILE: path to the
#                   federated WIF credentials file (optional; real push requires one)
#   CTR_CMD         container runtime (default: docker if exists, else podman)
# Dependencies: podman or docker (shim), git; gcloud only for real push
# Output:
#   stdout: info steps + resolved version + verified digest; stderr: errors
# Exit codes:
#   0  success (complete dry-run or complete real push)
#   1  validation failure: no semver tag, missing registry env vars, no
#      WIF credentials, divergent digest, local image missing, gcloud missing
#   2  usage error: IMAGE missing or invalid arguments
# ==============================================================================
set -Eeuo pipefail

usage() { # prints help; $1 = destination fd (1 stdout for --help, 2 for usage error)
  local text="Usage: IMAGE=<name> [SOURCE_TAG=<tag>] $(basename "$0") [--dry-run]
  --dry-run   validates resolution + local tags + digest and stops before push
  -h, --help  shows this help and exits 0

Environment variables (from pipeline/operator, not arguments):
  IMAGE (required), SOURCE_TAG (default latest), REGION, PROJECT_ID,
  REGISTRY_REPO, GIT_TAG, GOOGLE_APPLICATION_CREDENTIALS | CI_IAM_CREDENTIALS_FILE"
  if [[ "${1:-1}" == "2" ]]; then
    printf '%s\n' "$text" >&2
  else
    printf '%s\n' "$text"
  fi
}

die() { # $1 = error message -> STDERR + exit 1 (validation/security failure)
  printf 'error: %s\n' "$1" >&2
  exit 1
}

DRY_RUN=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage 1; exit 0 ;;
    *) usage 2; exit 2 ;;
  esac
  shift
done

if [[ -z "${IMAGE:-}" ]]; then
  usage 2
  exit 2
fi

# Semver tag resolved here (GIT_TAG or git describe --tags --exact-match)
resolve_version() { # prints canonical version vX.Y.Z; fails with clear message if no semver tag
  local raw="${GIT_TAG:-}"
  if [[ -z "$raw" ]]; then
    raw="$(git describe --tags --exact-match 2>/dev/null || true)"
  fi
  if [[ -z "$raw" ]]; then
    die "no valid semver tag: GIT_TAG empty and current commit has no exact git tag (git describe --tags --exact-match)"
  fi
  if [[ ! "$raw" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "invalid semver tag: '$raw' does not match pattern ^v?[0-9]+\\.[0-9]+\\.[0-9]+$ (vX.Y.Z required)"
  fi
  printf 'v%s\n' "${raw#v}"
}

VER="$(resolve_version)"
printf 'publish: resolved semver version: %s\n' "$VER"

# Available container runtime (podman or docker shim), override with CTR_CMD
CTR_CMD="${CTR_CMD:-}"
if [[ -z "$CTR_CMD" ]]; then
  if command -v docker >/dev/null 2>&1; then
    CTR_CMD="docker"
  elif command -v podman >/dev/null 2>&1; then
    CTR_CMD="podman"
  else
    die "container runtime not found: podman or docker required"
  fi
fi
SOURCE_TAG="${SOURCE_TAG:-latest}"

# Registry env vars gate: without target no push is possible and MUST NOT be attempted
if [[ -z "${REGION:-}" || -z "${PROJECT_ID:-}" || -z "${REGISTRY_REPO:-}" ]]; then
  die "missing registry variables: REGION, PROJECT_ID, and REGISTRY_REPO are required (target: <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_REPO>/$IMAGE)"
fi
TARGET_BASE="$REGION-docker.pkg.dev/$PROJECT_ID/$REGISTRY_REPO"

image_digest() { # $1 = local tag -> prints local digest ({{.Id}}) of that tag
  "$CTR_CMD" image inspect --format '{{.Id}}' "$1" 2>/dev/null || printf 'unknown\n'
}

# Local tagging: semver + latest on same build; both must point to SAME digest
if ! "$CTR_CMD" image inspect "$IMAGE:$SOURCE_TAG" >/dev/null 2>&1; then
  die "local image not found: $IMAGE:$SOURCE_TAG (build the image first)"
fi

"$CTR_CMD" tag "$IMAGE:$SOURCE_TAG" "$IMAGE:$VER" || die "failed to tag $IMAGE:$VER locally"
"$CTR_CMD" tag "$IMAGE:$SOURCE_TAG" "$IMAGE:latest" || die "failed to tag $IMAGE:latest locally"
DIG_VER="$(image_digest "$IMAGE:$VER")"
DIG_LATEST="$(image_digest "$IMAGE:latest")"
if [[ -z "$DIG_VER" || "$DIG_VER" == "unknown" || "$DIG_VER" != "$DIG_LATEST" ]]; then
  die "divergent digest: $IMAGE:$VER=$DIG_VER vs $IMAGE:latest=$DIG_LATEST (tags do NOT point to same build)"
fi
printf 'tagged: %s:%s -> %s\n' "$IMAGE" "$VER" "$DIG_VER"
printf 'tagged: %s:latest -> %s\n' "$IMAGE" "$DIG_LATEST"
printf 'digest ok: both tags point to same local digest %s\n' "$DIG_VER"

# Credentials detection can be reused in both modes
CRED_FILE=""
for f in "${GOOGLE_APPLICATION_CREDENTIALS:-}" "${CI_IAM_CREDENTIALS_FILE:-}"; do
  if [[ -n "$f" && -f "$f" ]]; then
    CRED_FILE="$f"
    break
  fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'dry-run: local validation OK; push to %s/%s:%s and :latest OMITTED (--dry-run, no network)\n' "$TARGET_BASE" "$IMAGE" "$VER"
  if [[ -n "$CRED_FILE" ]]; then
    printf 'dry-run: WIF credentials detected (%s); real push would use gcloud auth login --cred-file\n' "$CRED_FILE"
  else
    printf 'dry-run: WIF credentials NOT detected (GOOGLE_APPLICATION_CREDENTIALS/CI_IAM_CREDENTIALS_FILE) - real push requires federated credentials\n'
  fi
  exit 0
fi

# Real mode: never push without federated credentials (WIF), never static credentials
if [[ -z "$CRED_FILE" ]]; then
  die "WIF credentials not found: set GOOGLE_APPLICATION_CREDENTIALS or CI_IAM_CREDENTIALS_FILE with the federated file (nothing static in the repo)"
fi
if ! command -v gcloud >/dev/null 2>&1; then
  die "gcloud not in PATH: cannot authenticate with --cred-file; no push without federated auth"
fi

printf 'publish: authenticating WIF (gcloud auth login --cred-file %s)\n' "$CRED_FILE"
gcloud auth login --cred-file "$CRED_FILE" >/dev/null || die "WIF authentication failed with gcloud (--cred-file $CRED_FILE)"
printf 'publish: pushing %s/%s:%s\n' "$TARGET_BASE" "$IMAGE" "$VER"
"$CTR_CMD" push "$TARGET_BASE/$IMAGE:$VER" || die "push of $TARGET_BASE/$IMAGE:$VER failed"
printf 'publish: pushing %s/%s:latest\n' "$TARGET_BASE" "$IMAGE"
"$CTR_CMD" push "$TARGET_BASE/$IMAGE:latest" || die "push of $TARGET_BASE/$IMAGE:latest failed"
printf 'publish: published %s/%s:%s and :latest (digest %s)\n' "$TARGET_BASE" "$IMAGE" "$VER" "$DIG_VER"
exit 0