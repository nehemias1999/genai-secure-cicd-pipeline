#!/usr/bin/env bash
# ==============================================================================
# Description: Scans the local image with Trivy (vulnerabilities + secrets),
#   generates traceable JSON/HTML reports (digest + commit) under OUTDIR, applies
#   the severity gate (CRITICAL/HIGH by default, configurable) and runs a
#   non-blocking `trivy fs` scan over the repo root. The image scan uses --input
#   over a `docker save` archive: scans the local image without depending on a
#   registry or daemon (offline pattern, resilient to network).
# Author: implementer-req3 (SDD flow, requirement security-scan)
# Usage: ./scripts/run-trivy.sh <IMAGE> [OUTDIR] [THRESHOLD]
#   IMAGE     (required) local image tag, e.g., genai-secure-api:req3
#   OUTDIR    (optional, default reports/) directory where reports are persisted
#   THRESHOLD (optional, default CRITICAL,HIGH) severities that break the build
#   -h|--help prints help to STDOUT and exits 0
# Env Vars:
#   TRIVY_BIN       trivy binary (default: trivy in PATH)
#   CTR_CMD         runtime for docker save (default: docker if exists, else podman)
#   TRIVY_ARGS      extra flags for trivy image/fs, e.g., "--timeout 5m"
#   TRIVY_DB_MODE   skip | update | auto (default auto: --skip-db-update if DB
#                   already in local cache, else allows download)
#   TRIVY_CACHE_DIR trivy cache dir to detect DB (default ~/.cache/trivy)
#   SCAN_ROOT       path for trivy fs scan (default: current directory)
# Dependencies: trivy, docker (podman shim) or podman, jq, git
# Output:
#   $OUTDIR/trivy-image.json  JSON report of image scan (enriched with ScanTrace)
#   $OUTDIR/trivy-image.html  HTML report of image scan (digest/commit interpolated)
#   $OUTDIR/trivy-fs.json     JSON report of filesystem scan (non-blocking)
#   $OUTDIR/trivy-fs.html     HTML report of filesystem scan (non-blocking)
#   stdout: summary (counts by severity, digest, commit); stderr: errors
# Exit codes:
#   0  scan complete with no findings at threshold (LOW/MEDIUM don't break build)
#   1  severity gate: findings >= threshold (CRITICAL/HIGH by default)
#   2  usage error: missing required arguments
#   3  infrastructure failure (trivy, docker save, jq, template, or reports)
# ==============================================================================
set -Eeuo pipefail

usage() { # prints help; $1 = destination fd (1 stdout for --help, 2 for usage error)
  local text="Usage: $(basename "$0") <IMAGE> [OUTDIR] [THRESHOLD]
  IMAGE       local image to scan (required)
  OUTDIR      output directory for reports (default: reports/)
  THRESHOLD   severities that break the build, CSV (default: CRITICAL,HIGH)
Options:
  -h, --help  show this help and exit 0
Env: TRIVY_BIN, CTR_CMD, TRIVY_ARGS, TRIVY_DB_MODE, TRIVY_CACHE_DIR, SCAN_ROOT"
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

IMAGE="$1"
OUTDIR="${2:-reports/}"
THRESHOLD="${3:-CRITICAL,HIGH}"

TRIVY_ARGS="${TRIVY_ARGS:-}"
TRIVY_BIN="${TRIVY_BIN:-trivy}"
if ! command -v "$TRIVY_BIN" >/dev/null 2>&1; then
  printf 'error: binary %s not found in PATH (override with TRIVY_BIN)\n' "$TRIVY_BIN" >&2
  exit 3
fi

CTR_CMD="${CTR_CMD:-}"
if [[ -z "$CTR_CMD" ]]; then
  if command -v docker >/dev/null 2>&1; then
    CTR_CMD="docker"
  else
    CTR_CMD="podman"
  fi
fi

detect_db() { # 0 if vulnerability DB already in local cache
  local cache="${TRIVY_CACHE_DIR:-$HOME/.cache/trivy}"
  [[ -f "$cache/db/trivy.db" ]]
}

DB_FLAG=()
case "${TRIVY_DB_MODE:-auto}" in
  skip)   DB_FLAG=(--skip-db-update) ;;
  update) DB_FLAG=() ;;
  auto)   if detect_db; then DB_FLAG=(--skip-db-update); fi ;;
  *)      printf 'error: invalid TRIVY_DB_MODE (%s), use skip|update|auto\n' "${TRIVY_DB_MODE:-}" >&2; exit 3 ;;
esac

resolve_digest() { # $1 = image -> prints sha256 of RepoDigest (or Id as fallback)
  local digest=""
  digest="$("$CTR_CMD" image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || true)"
  if [[ "$digest" == *"@sha256:"* ]]; then
    printf '%s\n' "${digest##*@}"
  else
    "$CTR_CMD" image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || printf 'unknown\n'
  fi
}

IMAGE_DIGEST="$(resolve_digest)"
BUILD_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf 'unknown\n')"
SCAN_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$OUTDIR"

# Temporary image archive + copy .tpl template (trivy requires .tpl extension)
ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/trivy-image.XXXXXX.tar")"
TMPL_SRC="$(dirname "$0")/_trivy_html.tmpl"
TMPL_TMP="${ARCHIVE%.tar}.tpl"
if [[ ! -f "$TMPL_SRC" ]]; then
  printf 'error: HTML template not found: %s\n' "$TMPL_SRC" >&2
  exit 3
fi
cp "$TMPL_SRC" "$TMPL_TMP"
trap 'rm -f "$ARCHIVE" "$TMPL_TMP"' EXIT

"$CTR_CMD" save --output "$ARCHIVE" "$IMAGE" >/dev/null || {
  printf 'error: failed to archive image %s with %s\n' "$IMAGE" "$CTR_CMD" >&2
  exit 3
}

# Image JSON report (source of gate and traceability)
"$TRIVY_BIN" image --format json --output "$OUTDIR/trivy-image.json" \
  "${DB_FLAG[@]}" $TRIVY_ARGS --input "$ARCHIVE" || {
  printf 'error: trivy failed on image scan (%s)\n' "$IMAGE" >&2
  exit 3
}

# Image HTML report from custom template
"$TRIVY_BIN" image --format template --template "@$TMPL_TMP" --output "$OUTDIR/trivy-image.html" \
  "${DB_FLAG[@]}" $TRIVY_ARGS --input "$ARCHIVE" || {
  printf 'error: trivy failed to generate image HTML (%s)\n' "$IMAGE" >&2
  exit 3
}

# Traceability: enrich JSON with build context (ScanTrace)
jq --arg image "$IMAGE" \
   --arg digest "$IMAGE_DIGEST" \
   --arg commit "$BUILD_COMMIT" \
   --arg ts "$SCAN_TIMESTAMP" \
   --arg th "$THRESHOLD" \
   '. + {ScanTrace: {image: $image, imageDigest: $digest, commitSha: $commit, scanTimestamp: $ts, severityThreshold: $th}}' \
   "$OUTDIR/trivy-image.json" > "$OUTDIR/.trivy-image.json.tmp" && \
  mv "$OUTDIR/.trivy-image.json.tmp" "$OUTDIR/trivy-image.json" || {
    printf 'error: jq failed to enrich JSON report\n' >&2
    exit 3
  }

# Traceability: interpolate digest/commit/timestamp into HTML and JSON
sed -i \
  -e "s|__IMAGE_NAME__|$IMAGE|g" \
  -e "s|__IMAGE_DIGEST__|$IMAGE_DIGEST|g" \
  -e "s|__BUILD_COMMIT__|$BUILD_COMMIT|g" \
  -e "s|__SCAN_TIMESTAMP__|$SCAN_TIMESTAMP|g" \
  -e "s|__SEVERITY_THRESHOLD__|$THRESHOLD|g" \
  "$OUTDIR/trivy-image.html" || {
    printf 'error: failed to interpolate traceability into HTML\n' >&2
    exit 3
  }

# trivy fs over repo root: non-blocking (never breaks the flow on its own)
SCAN_ROOT="${SCAN_ROOT:-.}"
"$TRIVY_BIN" fs --format json --output "$OUTDIR/trivy-fs.json" \
  --skip-dirs "$OUTDIR" --skip-dirs ".git" "${DB_FLAG[@]}" $TRIVY_ARGS "$SCAN_ROOT" \
  >/dev/null 2>&1 || {
  printf 'warn: trivy fs failed (non-blocking): report may be missing or incomplete\n' >&2
}
if [[ -s "$OUTDIR/trivy-fs.json" ]]; then
  jq --arg image "$IMAGE" --arg digest "$IMAGE_DIGEST" --arg commit "$BUILD_COMMIT" \
     --arg ts "$SCAN_TIMESTAMP" --arg th "$THRESHOLD" \
     '. + {ScanTrace: {image: $image, imageDigest: $digest, commitSha: $commit, scanTimestamp: $ts, severityThreshold: $th}}' \
     "$OUTDIR/trivy-fs.json" > "$OUTDIR/.trivy-fs.json.tmp" && \
    mv "$OUTDIR/.trivy-fs.json.tmp" "$OUTDIR/trivy-fs.json"
  "$TRIVY_BIN" fs --format template --template "@$TMPL_TMP" --output "$OUTDIR/trivy-fs.html" \
    --skip-dirs "$OUTDIR" --skip-dirs ".git" "${DB_FLAG[@]}" $TRIVY_ARGS "$SCAN_ROOT" \
    >/dev/null 2>&1 || true
  sed -i \
    -e "s|__IMAGE_NAME__|$SCAN_ROOT|g" \
    -e "s|__IMAGE_DIGEST__|$IMAGE_DIGEST|g" \
    -e "s|__BUILD_COMMIT__|$BUILD_COMMIT|g" \
    -e "s|__SCAN_TIMESTAMP__|$SCAN_TIMESTAMP|g" \
    -e "s|__SEVERITY_THRESHOLD__|$THRESHOLD|g" \
    "$OUTDIR/trivy-fs.html" || true
fi

# Severity gate: any finding with severity in THRESHOLD breaks the build.
# []? at both levels: trivy emits "Results": null for clean images (e.g.
# scratch) and that must be treated as zero findings, not a jq error.
SEV_COUNTS="$(jq -r '[.Results[]?.Vulnerabilities[]?.Severity] | group_by(.) | map("\(.[0])=\(length)") | if length == 0 then "none" else join(" ") end' "$OUTDIR/trivy-image.json")"
BREACH=0
IFS=',' read -ra THRESHOLD_LIST <<< "$THRESHOLD"
for sev in $(jq -r '[.Results[]?.Vulnerabilities[]?.Severity] | unique[]' "$OUTDIR/trivy-image.json"); do
  for want in "${THRESHOLD_LIST[@]}"; do
    if [[ "$sev" == "$want" ]]; then
      BREACH=1
    fi
  done
done

printf 'scan: image=%s digest=%s commit=%s\n' "$IMAGE" "$IMAGE_DIGEST" "$BUILD_COMMIT"
printf 'findings by severity: %s\n' "${SEV_COUNTS:-none}"
printf 'gate breaks build: %s\n' "$THRESHOLD"
printf 'reports: %s/trivy-image.json, %s/trivy-image.html (fs non-blocking: trivy-fs.json/html)\n' "${OUTDIR%/}" "${OUTDIR%/}"

if [[ "$BREACH" -eq 1 ]]; then
  printf 'GATE: findings in severities %s detected -> build broken (exit 1)\n' "$THRESHOLD" >&2
  exit 1
fi

printf 'GATE: no findings in severities >= threshold (%s): LOW/MEDIUM do not break the build\n' "$THRESHOLD"
exit 0