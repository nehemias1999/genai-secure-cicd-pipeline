#!/usr/bin/env bash
# ==============================================================================
# Description: Genera el artifact de trazabilidad de build (build-metadata.json):
#   commit SHA, build URL, imagen y digest producido. El digest autoritativo
#   proviene del report JSON del scan (ScanTrace.imageDigest que enriquece
#   scripts/run-trivy.sh); si el scan no corrio aun, cae al digest local del
#   runtime de contenedor (RepoDigests[0] o Id), igual que run-trivy.sh. Fuera
#   de Jenkins (sin BUILD_URL) el campo buildUrl se emite vacio: el artifact es
#   igualmente valido para trazabilidad local.
# Author: implementer-req5 (SDD flow, requisito cicd-pipeline)
# Usage: ./scripts/build-metadata.sh <IMAGE> [OUTDIR]
#   IMAGE   (obligatorio) tag de la imagen local, ej. genai-secure-api:latest
#   OUTDIR  (opcional, default reports/) directorio de salida del artifact
#   -h|--help imprime la ayuda en STDOUT y sale 0
# Env Vars:
#   GIT_COMMIT  commit del checkout (lo fija Jenkins); si ausente usa git rev-parse
#   BUILD_URL   URL del build (la fija Jenkins); si ausente se emite el campo vacio
#   CTR_CMD     runtime de contenedor (default: docker si existe, si no podman)
# Dependencies: jq, git, docker (o podman)
# Output:
#   $OUTDIR/build-metadata.json  JSON {commitSha, buildUrl, image, imageDigest, buildTimestamp}
#   stdout: ruta del artifact generado; stderr: errores y warnings
# Exit codes:
#   0  artifact generado correctamente
#   2  error de uso: faltan argumentos obligatorios
#   3  fallo de infraestructura: jq ausente o report JSON invalido
# ==============================================================================
set -Eeuo pipefail

usage() { # imprime la ayuda; $1 = fd destino (1 stdout para --help, 2 para error de uso)
  local text="Usage: $(basename "$0") <IMAGE> [OUTDIR]
  IMAGE       imagen local a registrar en la metadata (obligatorio)
  OUTDIR      directorio de salida del artifact (default: reports/)
Opciones:
  -h, --help  muestra esta ayuda y sale 0
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
  printf 'error: jq no encontrado en PATH (dependencia obligatoria)\n' >&2
  exit 3
fi

IMAGE="$1"
OUTDIR="${2:-reports/}"
mkdir -p "$OUTDIR"

# Commit: GIT_COMMIT lo provee el checkout de Jenkins; en local cae al HEAD del repo
COMMIT="${GIT_COMMIT:-$(git rev-parse HEAD 2>/dev/null || printf 'unknown\n')}"
COMMIT="${COMMIT:-unknown}"
BUILD_URL="${BUILD_URL:-}"
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Digest autoritativo: ScanTrace del report JSON de trivy (lo enriquece
# scripts/run-trivy.sh). Si el scan aun no corrio, cae al digest local.
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
    printf 'error: jq fallo al generar build-metadata.json\n' >&2
    exit 3
  }

printf 'metadata: %s (commit=%s image=%s digest=%s)\n' "$OUTDIR/build-metadata.json" "$COMMIT" "$IMAGE" "$DIGEST"
exit 0