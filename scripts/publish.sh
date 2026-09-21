#!/usr/bin/env bash
# ==============================================================================
# Description: Etiqueta la imagen local con semver ($IMAGE:vX.Y.Z) y latest y la
#   publica a GCP Artifact Registry via Workload Identity Federation (nunca
#   credenciales estaticas). La version semver se resuelve del env GIT_TAG o del
#   git tag exacto del commit actual (patron vX.Y.Z). El modo --dry-run valida
#   toda la logica local (resolucion, tags locales, checksum de digest) sin
#   tocar la red ni registros.
# Author: implementer-req4 (SDD flow, requisito registry-publish)
# Usage: IMAGE=<name> [SOURCE_TAG=<tag>] scripts/publish.sh [--dry-run]
#   --dry-run  valida resolucion + tags locales + digest y se detiene antes del
#              push (no toca red); util sin credenciales GCP reales
#   -h|--help  imprime la ayuda en STDOUT y sale 0
# Env Vars:
#   IMAGE           (obligatorio) nombre de la imagen SIN tag, ej. genai-secure-api
#   SOURCE_TAG      tag local origen del build (default: latest), ej. req4-test
#   REGION          region de Artifact Registry, ej. us-central1 (obligatoria)
#   PROJECT_ID      proyecto GCP (obligatorio)
#   REGISTRY_REPO   repositorio de Artifact Registry (obligatorio)
#   GIT_TAG         tag semver vX.Y.Z (opcional; default: git describe --tags --exact-match)
#   GOOGLE_APPLICATION_CREDENTIALS / CI_IAM_CREDENTIALS_FILE: ruta al archivo de
#                   credenciales federadas WIF (opcional; el push real exige una)
#   CTR_CMD         runtime de contenedor (default: docker si existe, si no podman)
# Dependencies: podman o docker (shim), git; gcloud solo para push real
# Output:
#   stdout: pasos info + version resuelta + digest verificado; stderr: errores
# Exit codes:
#   0  exito (dry-run completo o push real completo)
#   1  fallo de validacion: sin tag semver, faltan env vars de registry, sin
#      credenciales WIF, digest divergente, imagen local inexistente, gcloud ausente
#   2  error de uso: IMAGE faltante o argumentos invalidos
# ==============================================================================
set -Eeuo pipefail

usage() { # imprime la ayuda; $1 = fd destino (1 stdout para --help, 2 para error de uso)
  local text="Usage: IMAGE=<name> [SOURCE_TAG=<tag>] $(basename "$0") [--dry-run]
  --dry-run   valida resolucion + tags locales + digest y se detiene antes del push
  -h, --help  muestra esta ayuda y sale 0

Variables de entorno (provenientes del pipeline/operador, no argumentos):
  IMAGE (obligatorio), SOURCE_TAG (default latest), REGION, PROJECT_ID,
  REGISTRY_REPO, GIT_TAG, GOOGLE_APPLICATION_CREDENTIALS | CI_IAM_CREDENTIALS_FILE"
  if [[ "${1:-1}" == "2" ]]; then
    printf '%s\n' "$text" >&2
  else
    printf '%s\n' "$text"
  fi
}

die() { # $1 = mensaje de error -> STDERR + exit 1 (fallo de validacion/seguridad)
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

# El tag semver se resuelve aqui (GIT_TAG o git describe --tags --exact-match)
resolve_version() { # imprime la version canonica vX.Y.Z; falla con mensaje claro si no hay tag semver
  local raw="${GIT_TAG:-}"
  if [[ -z "$raw" ]]; then
    raw="$(git describe --tags --exact-match 2>/dev/null || true)"
  fi
  if [[ -z "$raw" ]]; then
    die "no hay tag semver valido: GIT_TAG vacio y el commit actual no tiene git tag exacto (git describe --tags --exact-match)"
  fi
  if [[ ! "$raw" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "tag semver invalido: '$raw' no cumple el patron ^v?[0-9]+\.[0-9]+\.[0-9]+$ (se requiere vX.Y.Z)"
  fi
  printf 'v%s\n' "${raw#v}"
}

VER="$(resolve_version)"
printf 'publish: version semver resuelta: %s\n' "$VER"

# Runtime de contenedor disponible (podman o docker shim), override con CTR_CMD
CTR_CMD="${CTR_CMD:-}"
if [[ -z "$CTR_CMD" ]]; then
  if command -v docker >/dev/null 2>&1; then
    CTR_CMD="docker"
  elif command -v podman >/dev/null 2>&1; then
    CTR_CMD="podman"
  else
    die "runtime de contenedor no encontrado: se requiere podman o docker"
  fi
fi
SOURCE_TAG="${SOURCE_TAG:-latest}"

# Gate de env vars de registry: sin el target no hay push posible y NO debe intentarse
if [[ -z "${REGION:-}" || -z "${PROJECT_ID:-}" || -z "${REGISTRY_REPO:-}" ]]; then
  die "faltan variables de registry: REGION, PROJECT_ID y REGISTRY_REPO son obligatorias (target: <REGION>-docker.pkg.dev/<PROJECT_ID>/<REGISTRY_REPO>/$IMAGE)"
fi
TARGET_BASE="$REGION-docker.pkg.dev/$PROJECT_ID/$REGISTRY_REPO"

image_digest() { # $1 = tag local -> imprime el digest local ({{.Id}}) de ese tag
  "$CTR_CMD" image inspect --format '{{.Id}}' "$1" 2>/dev/null || printf 'unknown\n'
}

# Etiquetado local: semver + latest sobre el mismo build; ambos deben apuntar al MISMO digest
if ! "$CTR_CMD" image inspect "$IMAGE:$SOURCE_TAG" >/dev/null 2>&1; then
  die "imagen local no encontrada: $IMAGE:$SOURCE_TAG (construi primero la imagen)"
fi

"$CTR_CMD" tag "$IMAGE:$SOURCE_TAG" "$IMAGE:$VER" || die "fallo el etiquetado local de $IMAGE:$VER"
"$CTR_CMD" tag "$IMAGE:$SOURCE_TAG" "$IMAGE:latest" || die "fallo el etiquetado local de $IMAGE:latest"
DIG_VER="$(image_digest "$IMAGE:$VER")"
DIG_LATEST="$(image_digest "$IMAGE:latest")"
if [[ -z "$DIG_VER" || "$DIG_VER" == "unknown" || "$DIG_VER" != "$DIG_LATEST" ]]; then
  die "digest divergente: $IMAGE:$VER=$DIG_VER vs $IMAGE:latest=$DIG_LATEST (los tags NO apuntan al mismo build)"
fi
printf 'tagged: %s:%s -> %s\n' "$IMAGE" "$VER" "$DIG_VER"
printf 'tagged: %s:latest -> %s\n' "$IMAGE" "$DIG_LATEST"
printf 'digest ok: ambos tags apuntan al mismo digest local %s\n' "$DIG_VER"

# Ahora la deteccion de credenciales puede reutilizarse en ambos modos
CRED_FILE=""
for f in "${GOOGLE_APPLICATION_CREDENTIALS:-}" "${CI_IAM_CREDENTIALS_FILE:-}"; do
  if [[ -n "$f" && -f "$f" ]]; then
    CRED_FILE="$f"
    break
  fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'dry-run: validacion local OK; push a %s/%s:%s y :latest OMITIDO (--dry-run, no se toca red)\n' "$TARGET_BASE" "$IMAGE" "$VER"
  if [[ -n "$CRED_FILE" ]]; then
    printf 'dry-run: credenciales WIF detectadas (%s); con push real se usaria gcloud auth login --cred-file\n' "$CRED_FILE"
  else
    printf 'dry-run: credenciales WIF NO detectadas (GOOGLE_APPLICATION_CREDENTIALS/CI_IAM_CREDENTIALS_FILE) - el push real requiere credenciales federadas\n'
  fi
  exit 0
fi

# Modo real: nunca push sin credenciales federadas (WIF), nunca credenciales estaticas
if [[ -z "$CRED_FILE" ]]; then
  die "credenciales WIF no encontradas: setear GOOGLE_APPLICATION_CREDENTIALS o CI_IAM_CREDENTIALS_FILE con el archivo federado (nada estatico en el repo)"
fi
if ! command -v gcloud >/dev/null 2>&1; then
  die "gcloud no esta en PATH: imposible autenticar con --cred-file; no se hace push sin autenticacion federada"
fi

printf 'publish: autenticando WIF (gcloud auth login --cred-file %s)\n' "$CRED_FILE"
gcloud auth login --cred-file "$CRED_FILE" >/dev/null || die "fallo la autenticacion WIF con gcloud (--cred-file $CRED_FILE)"
printf 'publish: pushing %s/%s:%s\n' "$TARGET_BASE" "$IMAGE" "$VER"
"$CTR_CMD" push "$TARGET_BASE/$IMAGE:$VER" || die "fallo el push de $TARGET_BASE/$IMAGE:$VER"
printf 'publish: pushing %s/%s:latest\n' "$TARGET_BASE" "$IMAGE"
"$CTR_CMD" push "$TARGET_BASE/$IMAGE:latest" || die "fallo el push de $TARGET_BASE/$IMAGE:latest"
printf 'publish: publicado %s/%s:%s y :latest (digest %s)\n' "$TARGET_BASE" "$IMAGE" "$VER" "$DIG_VER"
exit 0