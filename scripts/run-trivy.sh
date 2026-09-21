#!/usr/bin/env bash
# ==============================================================================
# Description: Escanea la imagen local con Trivy (vulnerabilidades + secretos),
#   genera reports JSON/HTML trazables (digest + commit) bajo OUTDIR, aplica el
#   gate de severidad (CRITICAL/HIGH por defecto, configurable) y corre un
#   escaneo `trivy fs` no-bloqueante sobre la raiz del repo. El scan de imagen
#   usa --input sobre un archive de `docker save`: escanea la imagen local sin
#   depender de un registry ni de un daemon (patron offline, resiliente a red).
# Author: implementer-req3 (SDD flow, requisito security-scan)
# Usage: ./scripts/run-trivy.sh <IMAGE> [OUTDIR] [THRESHOLD]
#   IMAGE     (obligatorio) tag de la imagen local, ej. genai-secure-api:req3
#   OUTDIR    (opcional, default reports/) directorio donde se persisten reports
#   THRESHOLD (opcional, default CRITICAL,HIGH) severidades que rompen el build
#   -h|--help imprime la ayuda en STDOUT y sale 0
# Env Vars:
#   TRIVY_BIN       binario trivy (default: trivy en PATH)
#   CTR_CMD         runtime para docker save (default: docker si existe, si no podman)
#   TRIVY_ARGS      flags extra para trivy image/fs, ej. "--timeout 5m"
#   TRIVY_DB_MODE   skip | update | auto (default auto: --skip-db-update si la
#                   DB ya esta en la cache local, si no permite descargarla)
#   TRIVY_CACHE_DIR dir de cache de trivy para detectar la DB (default ~/.cache/trivy)
#   SCAN_ROOT       ruta del escaneo trivy fs (default: directorio actual)
# Dependencies: trivy, docker (shim de podman) o podman, jq, git
# Output:
#   $OUTDIR/trivy-image.json  report JSON del scan de imagen (enriquecido con ScanTrace)
#   $OUTDIR/trivy-image.html  report HTML del scan de imagen (digest/commit interpolados)
#   $OUTDIR/trivy-fs.json     report JSON del scan de filesystem (no-bloqueante)
#   $OUTDIR/trivy-fs.html     report HTML del scan de filesystem (no-bloqueante)
#   stdout: resumen (conteos por severidad, digest, commit); stderr: errores
# Exit codes:
#   0  scan completo sin findings en el umbral (LOW/MEDIUM no rompen el build)
#   1  gate de severidad: hay findings >= umbral (CRITICAL/HIGH por default)
#   2  error de uso: faltan argumentos obligatorios
#   3  fallo de infraestructura (trivy, docker save, jq, template o reports)
# ==============================================================================
set -Eeuo pipefail

usage() { # imprime la ayuda; $1 = fd destino (1 stdout para --help, 2 para error de uso)
  local text="Usage: $(basename "$0") <IMAGE> [OUTDIR] [THRESHOLD]
  IMAGE       imagen local a escanear (obligatorio)
  OUTDIR      directorio de salida de reports (default: reports/)
  THRESHOLD   severidades que rompen el build, CSV (default: CRITICAL,HIGH)
Opciones:
  -h, --help  muestra esta ayuda y sale 0
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
  printf 'error: binario %s no encontrado en PATH (override con TRIVY_BIN)\n' "$TRIVY_BIN" >&2
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

detect_db() { # 0 si la DB de vulnerabilidades ya esta en la cache local
  local cache="${TRIVY_CACHE_DIR:-$HOME/.cache/trivy}"
  [[ -f "$cache/db/trivy.db" ]]
}

DB_FLAG=()
case "${TRIVY_DB_MODE:-auto}" in
  skip)   DB_FLAG=(--skip-db-update) ;;
  update) DB_FLAG=() ;;
  auto)   if detect_db; then DB_FLAG=(--skip-db-update); fi ;;
  *)      printf 'error: TRIVY_DB_MODE invalido (%s), use skip|update|auto\n' "${TRIVY_DB_MODE:-}" >&2; exit 3 ;;
esac

resolve_digest() { # $1 = imagen -> imprime sha256 del RepoDigest (o del Id como fallback)
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

# Archive temporal de la imagen + copia .tpl del template (trivy exige extension .tpl)
ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/trivy-image.XXXXXX.tar")"
TMPL_SRC="$(dirname "$0")/_trivy_html.tmpl"
TMPL_TMP="${ARCHIVE%.tar}.tpl"
if [[ ! -f "$TMPL_SRC" ]]; then
  printf 'error: template HTML no encontrado: %s\n' "$TMPL_SRC" >&2
  exit 3
fi
cp "$TMPL_SRC" "$TMPL_TMP"
trap 'rm -f "$ARCHIVE" "$TMPL_TMP"' EXIT

"$CTR_CMD" save --output "$ARCHIVE" "$IMAGE" >/dev/null || {
  printf 'error: fallo al archivar la imagen %s con %s\n' "$IMAGE" "$CTR_CMD" >&2
  exit 3
}

# Report JSON de la imagen (fuente del gate y de la trazabilidad)
"$TRIVY_BIN" image --format json --output "$OUTDIR/trivy-image.json" \
  "${DB_FLAG[@]}" $TRIVY_ARGS --input "$ARCHIVE" || {
  printf 'error: trivy fallo en el scan de imagen (%s)\n' "$IMAGE" >&2
  exit 3
}

# Report HTML de la imagen desde el template custom
"$TRIVY_BIN" image --format template --template "@$TMPL_TMP" --output "$OUTDIR/trivy-image.html" \
  "${DB_FLAG[@]}" $TRIVY_ARGS --input "$ARCHIVE" || {
  printf 'error: trivy fallo al generar el HTML de la imagen (%s)\n' "$IMAGE" >&2
  exit 3
}

# Trazabilidad: digerir el JSON con el contexto del build (ScanTrace)
jq --arg image "$IMAGE" \
   --arg digest "$IMAGE_DIGEST" \
   --arg commit "$BUILD_COMMIT" \
   --arg ts "$SCAN_TIMESTAMP" \
   --arg th "$THRESHOLD" \
   '. + {ScanTrace: {image: $image, imageDigest: $digest, commitSha: $commit, scanTimestamp: $ts, severityThreshold: $th}}' \
   "$OUTDIR/trivy-image.json" > "$OUTDIR/.trivy-image.json.tmp" && \
  mv "$OUTDIR/.trivy-image.json.tmp" "$OUTDIR/trivy-image.json" || {
    printf 'error: jq fallo al enriquecer el report JSON\n' >&2
    exit 3
  }

# Trazabilidad: interpolar digest/commit/timestamp en el HTML y el JSON
sed -i \
  -e "s|__IMAGE_NAME__|$IMAGE|g" \
  -e "s|__IMAGE_DIGEST__|$IMAGE_DIGEST|g" \
  -e "s|__BUILD_COMMIT__|$BUILD_COMMIT|g" \
  -e "s|__SCAN_TIMESTAMP__|$SCAN_TIMESTAMP|g" \
  -e "s|__SEVERITY_THRESHOLD__|$THRESHOLD|g" \
  "$OUTDIR/trivy-image.html" || {
    printf 'error: fallo al interpolar la trazabilidad en el HTML\n' >&2
    exit 3
  }

# trivy fs sobre la raiz del repo: no-bloqueante (nunca rompe el flujo por si solo)
SCAN_ROOT="${SCAN_ROOT:-.}"
"$TRIVY_BIN" fs --format json --output "$OUTDIR/trivy-fs.json" \
  --skip-dirs "$OUTDIR" --skip-dirs ".git" "${DB_FLAG[@]}" $TRIVY_ARGS "$SCAN_ROOT" \
  >/dev/null 2>&1 || {
  printf 'warn: trivy fs fallo (no bloquea): el report puede faltar o estar incompleto\n' >&2
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

# Gate de severidad: cualquier finding con severidad en THRESHOLD rompe el build.
# []? en ambos niveles: trivy emite "Results": null para imagenes limpias (p. ej.
# scratch) y eso debe tratarse como cero findings, no como error de jq.
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
printf 'findings por severidad: %s\n' "${SEV_COUNTS:-none}"
printf 'gate rompe-build: %s\n' "$THRESHOLD"
printf 'reports: %s/trivy-image.json, %s/trivy-image.html (fs no-bloqueante: trivy-fs.json/html)\n' "${OUTDIR%/}" "${OUTDIR%/}"

if [[ "$BREACH" -eq 1 ]]; then
  printf 'GATE: findings en severidades %s detectados -> build roto (exit 1)\n' "$THRESHOLD" >&2
  exit 1
fi

printf 'GATE: sin findings en severidades >= umbral (%s): LOW/MEDIUM no rompen el build\n' "$THRESHOLD"
exit 0