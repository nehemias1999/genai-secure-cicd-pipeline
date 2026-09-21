# genai-secure-cicd-pipeline

Secure, end-to-end CI/CD pipeline for a Python GenAI application. Features multi-stage Docker builds, Trivy vulnerability scanning, and automated cloud registry publishing.

> Build status, coverage y version badges vendrán del CI real cuando el pipeline esté autogenerando artefactos publicables.

## Background

DevSecOps showcase: una API FastAPI dummy de generación con LLM pasa por un pipeline CI/CD completo — validación de código (lint + tests), build multi-stage reproducible, escaneo de vulnerabilidades con Trivy y publicación a GCP Artifact Registry — con gates de seguridad y trazabilidad de build en cada etapa.

Se diferencia de pipelines de ejemplo por ser *secure by default*:

- **Multi-stage Docker build** con deps pinneadas y runtime no-root; las dev deps nunca entran a la imagen final.
- **Gate de vulnerabilidades**: el escaneo Trivy **falla** cuando hay hallazgos CRITICAL/HIGH (umbral configurable).
- **Cero secretos estáticos**: credenciales WIF solo en el CI secret store / env del operador; la key del LLM se inyecta solo en runtime.
- **Trazabilidad**: cada run produce metadata (commit SHA + build URL + digests de imagen).

Los requisitos viven en `openspec/` (OpenSpec) como fuente de verdad; los cambios se desarrollaron con SDD (spec-driven development: TDD estricto por requisito, review independiente, gate humano por requisito, entrega con PR+merge).

### Tecnologías

| Capa | Stack |
|---|---|
| App | Python 3.12, FastAPI, uvicorn |
| Build | Docker multi-stage + labels OCI (build-args: `GIT_SHA`, `REPO_URL`, `BUILD_TIMESTAMP`) |
| Scan | Trivy (image + filesystem, modo offline, salida JSON + HTML) |
| Publish | GCP Artifact Registry + Workload Identity Federation, tags semver + `latest` |
| CI/CD | Pipeline declarativo Jenkins (Jenkinsfile) |

### Arquitectura / Flujo

```
commit → Checkout & Lint (flake8) → Unit tests (pytest)
       → Build (docker build, no-root runtime, labels OCI)
       → Security Scan (scripts/run-trivy.sh → exit≠0 si CRITICAL/HIGH)
       → Publish (scripts/publish.sh — gated a main + PUBLISH_MODE=real, si no dry-run)
       └─ artefactos: reports/trivy-* + build-metadata.json (commitSha, buildUrl, digests)
```

La lógica vive en `scripts/` (bash con `code-doc-standard`) que el Jenkinsfile consume; nada de lógica inline compleja en el pipeline.

## Install

### Prerrequisitos

- Docker ≥ 24 (o podman ≥ 4 como drop-in: `CTR_CMD=podman`)
- Python 3.12 + venv
- Trivy ≥ 0.50 con DB local (modo offline) con `.trivy.tpl` o el template `_trivy_html.tmpl`
- Jenkins ≥ 2 (solo si se va a correr el pipeline; ver `Jenkinsfile`)

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt   # runtime + pytest + flake8 pinneados
```

### Imagen

```bash
docker build -t genai-cicd-demo:dev .
```

## Usage

### API local

```bash
uvicorn src.main:app --reload
# GET  /health   → {"status":"ok",...}
# POST /generate {"prompt":"..."}   → contenido simulado (GEMINI_API_KEY solo en runtime)
```

### Pipeline CI/CD

Los scripts son ejecutables e idempotentes, con `--help`:

```bash
# Scan de seguridad con gate CRITICAL/HIGH + reportes JSON/HTML
scripts/run-trivy.sh <image:tag> reports/
# Exit codes: 0 = sin hallazgos sobre el umbral; 1 = bloqueante (pone el pipeline en FAIL)

# Publicación con dry-run por defecto (sin red). Para release real:
#   registrar el tag semver v1.2.3 en git y setear las env de registry + PUBLISH_MODE=real
scripts/publish.sh --dry-run   # o sin flag: semver desde git tag + verify mismo digest
```

### Trazabilidad

Cada run del pipeline archiva `build-metadata.json` con `{commitSha, buildUrl, image, imageDigest, buildTimestamp}` (generado por `scripts/build-metadata.sh`).

## API / Configuration

### Variables de entorno

#### Runtime de la API

| Variable | Requerida | Default | Descripción |
|---|---|---|---|
| `GEMINI_API_KEY` | runtime | — | Key del LLM; se inyecta solo en runtime, nunca embebida ni en la imagen |

#### Scripts del pipeline

| Variable | Requerida | Default | Descripción |
|---|---|---|---|
| `IMAGE_NAME` | scan/publish | — | Nombre de la imagen |
| `IMAGE_TAG` | scan/publish | — | Tag a escanear/publicar |
| `THRESHOLD` | scan | `CRITICAL` | Severidad desde la cual el escaneo bloquea (ej.: `CRITICAL`, `HIGH`) |
| `TRIVY_BIN` | scan | `trivy` | Ruta del binario de Trivy |
| `TRIVY_CACHE_DIR` | scan | `~/.cache/trivy` | Cache de la DB descargada (offline) |
| `TRIVY_DB_MODE` | scan | `db` | Modo `db` (ocon índice) — req3 |
| `CTR_CMD` | build/scan | `docker` | `docker` o `podman` |
| `REGION` | publish | — | Región GCP del registry |
| `PROJECT_ID` | publish | — | Proyecto GCP |
| `REGISTRY_REPO` | publish | — | Repo de Artifact Registry |
| `CI_IAM_CREDENTIALS_FILE` | publish real | — | Credenciales WIF vía Jenkins `withCredentials` (env del operador), jamás literal |
| `PUBLISH_MODE` | publish | `real` | `real` desde `main` + creds; cualquier otro valor fuerza `--dry-run` |

La del pipeline declarativo define `BUILD_URL`, `GIT_COMMIT`, `BUILD_TIMESTAMP` automáticamente.

### Pipeline Jenkins

`Jenkinsfile` declarativo, stages en orden estricto con fail-fast (`set -euo pipefail`, sin `|| true`):
**Checkout & Lint → Unit tests → Build → Security Scan → Publish**. El Publish real está gated: solo corre en `main` con `PUBLISH_MODE=real` y credenciales WIF provisionadas; en PRs sin tag semver, el dry-run reporta el fallo (ver nota en `scripts/publish.sh`).

## Contributing

### Entorno de desarrollo

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
```

### Verificaciones

```bash
python3 -m flake8 --max-line-length=88 --extend-ignore=W292 src/ tests/
python3 -m pytest -q
bash -n scripts/*.sh
openspec validate
```

Convención de commits: Conventional Commits (`feat`, `fix`, `chore`, `docs`). El flujo de desarrollo es SDD (spec-driven): los cambios nuevos se proponen en `openspec/changes/`, se implementan por requisito con TDD y se entregan con PR+merge (nunca push directo a `main`).

## License

MIT declarada en el proyecto (`openspec/`); el repo no incluye archivo `LICENSE` todavía.

## Docs

- [Especificación OpenSpec](openspec/) — fuente de verdad de requisitos (specs aplicadas + histórico en `openspec/changes/archive/`).
- `docs/agent-contract/` — contratos de asignación de cada requisito (SDD).
- Estándares: `code-doc-standard` y `readme-standard`.

_Última actualización README: 2026-09-21 (cierre del change `secure-cicd-pipeline`, req1–req5 integrados)._