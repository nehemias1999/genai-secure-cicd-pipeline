# Contrato de asignación — Requisito 3: security-scan

## Contexto

Proyecto: `genai-secure-cicd-pipeline` (DevOps showcase: FastAPI dummy + build inmutable + CI/CD seguro).
Cambio OpenSpec: `secure-cicd-pipeline`. Ya entregados: Req 1 (api) y Req 2 (container), ambos mergeados en `main`.

Este requisito implementa el escaneo de seguridad de la imagen con Trivy: gate de severidad (CRITICAL/HIGH), reports JSON+HTML trazables (digest + commit) y escaneo `trivy fs` no-bloqueante.

## Spec de referencia (leer)

- `openspec/changes/secure-cicd-pipeline/specs/security-scan/spec.md` — criterios de aceptación (fuente de verdad).
- `openspec/changes/secure-cicd-pipeline/tasks.md` — sección 4 (4.1–4.4).
- `openspec/changes/secure-cicd-pipeline/design.md` — decisión D3 (Trivy local image scan, json + html template, severity CRITICAL/HIGH exit 1).

## PERMITIDOS (archivos que puedes crear/editar)

- `scripts/run-trivy.sh` (nuevo) — script de escaneo.
- `scripts/_trivy_html.tmpl` (nuevo, opcional) — template HTML si se necesita uno custom.
- `reports/` (nuevo directorio donde se persisten reports; incluir `.gitkeep`).
- `.gitignore` (líneas para `reports/` y `*.trivy.db` si hacen falta).
- `docs/agent-contract/req3-security-scan.md` — está prohibido editarlo.

## NUNCA (prohibido tocar)

- `openspec/**` — spec, nunca la modifiques.
- `src/`, `tests/`, `Dockerfile`, `requirements*.txt`, `Jenkinsfile`, `README.md`.
- `docs/agent-contract/req2-*.md` y `req1-*.md`.

## Contrato de interfaz (lo que debe producir)

`scripts/run-trivy.sh` — script bash ejecutable, con:

- Argumentos POSICIONALES (documentados con `code-doc-standard`):
  1. `IMAGE` (obligatorio): nombre/tag de la imagen local a escanear.
  2. `OUTDIR` (opcional, default `reports/`): directorio de salida.
  3. `THRESHOLD` (opcional, default `CRITICAL,HIGH`): severidades que rompen el build.
- Puede soportar env vars para overrides (p. ej. `TRIVY_ARGS`, timeout de red) manteniendo los defaults de la spec.
- **Comportamiento**:
  - Corre `trivy image --format json` (para parsear y para el report JSON).
  - Corre `trivy image --format template --template @<tmpl>` (o `--format html` equivalente soportado por la versión instalada) para el report HTML.
  - **Gate de severidad**: fail exit ≠0 si hay findings CRITICAL o HIGH (>= umbral). Severidades MEDIUM/LOW se reportan pero NO rompen el build.
  - Reports escritos en `$OUTDIR/` con nombres estables, p. ej. `trivy-image.json`, `trivy-image.html`.
  - **Trazabilidad**: los reportes deben registrar digest de la imagen escaneada Y commit SHA de la build. Si se usa template HTML custom, debe interpolar digest+commit; el JSON de trivy ya incluye metadata si se pasa `--format json` + se puede enriquecer.
  - `trivy fs` sobre la raíz del repo: se ejecuta y reporta findings PERO **no** rompe pipelina (no bloquear).
- El script debe ser resiliente a red lenta / DB no descargada (documentar; usar `--skip-db-update` cuando la DB ya existe localmente o `TRIVY_*` overrides).

## Perfil de verificación del entorno

- **Container runtime**: podman rootless 6.1.2 (`docker` es un shim de podman). En este sandbox el port-bridge `-p` no funciona; para healthchecks usar `--network=host`.
- **Trivy**: instalado en `~/.local/bin/trivy` v0.74.0, DB de vulnerabilidades ya descargada a `~/.cache/trivy`. Si un comando no encuentra `trivy`, usa la ruta completa `$HOME/.local/bin/trivy`.
- **Imagen base**: construida en Req 2 — `docker build`/`podman build` con tags OCI desde `Dockerfile` (multi-stage, `python:3.12.6-slim-bookworm`).
- **Comandos de verificación del perfil (debes correrlos todos y adjuntar salida real)**:
  - `bash -n scripts/run-trivy.sh`
  - `shellcheck scripts/run-trivy.sh` si está instalado (si no, anótalo)
  - `python3 -m pytest` y `python3 -m flake8` (regresión: no debes romper el state actual, aunque no los edites)
  - `podman build -t genai-secure-api:req3-test .` (en la raíz del repo)
  - `scripts/run-trivy.sh genai-secure-api:req3-test` y verificar que genere los reports, inyecte digest+commit, y que el estado de salida siga el gate.
  - Verificación de trazabilidad: parsear los reports y mostrar digest + commit presentes.
  - Trivy fs no-bloqueante: correr `trivy fs . ` (o via el script) y confirmar que no rompe el flujo.

## DoD (Definition of Done)

- [ ] `scripts/run-trivy.sh` existente, ejecutable (`chmod +x`), documentado con `code-doc-standard`.
- [ ] `bash -n` pasa; shellcheck limpio si está disponible.
- [ ] Escaneo real de la imagen local funciona: genera `trivy-image.json` y `trivy-image.html` en `reports/`.
- [ ] Gate CRITICAL/HIGH probado: exit≠0 ante findings graves; conocer el comportamiento con imagen limpia (exit 0).
- [ ] Reports contienen digest de imagen y commit SHA (evidencia de parseo).
- [ ] `trivy fs` corre como no-bloqueante.
- [ ] No tocas `openspec/`, no rompes pytest/flake8 existentes.
- [ ] Sin secretos en el diff (nada de keys/credenciales, hardcodings).

## Reporte final del implementer (estructura

```
status: DONE | BLOCKED | NEEDS_CONTEXT
requirement: req3-security-scan
tests: <N passed / N failed> (<comando>)
verification: <bash -n / shellcheck / podman build / trivy run / openspec validate>
files: <archivos creados/modificados>
evidence: <1-2 líneas de output real; incluir exit codes y digest>
notes: <desviaciones si las hay>
```

No pegues diffs ni volcados largos. Si algo del entorno bloquea (red, permisos), reportá `BLOCKED` con el error real; no improvises un trabajo a medias.