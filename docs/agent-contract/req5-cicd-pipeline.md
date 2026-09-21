# Contrato de asignación — Requisito 5: cicd-pipeline

## Contexto

Proyecto: `genai-secure-cicd-pipeline` (DevOps showcase). Cambio OpenSpec: `secure-cicd-pipeline`.
Ya en `main`: Req 1 (api), Req 2 (container), Req 3 (security-scan), Req 4 (registry-publish).

Este requisito define el pipeline declarativo (Jenkinsfile) que orquesta el ciclo completo:
validación → build → security scan → publish, con gates y trazabilidad de build. Es el último
requisito de la feature; tras este se hará el README y el apply/archive del change.

## Spec de referencia (leer)

- `openspec/changes/secure-cicd-pipeline/specs/cicd-pipeline/spec.md` — criterios de aceptación (fuente de verdad).
- `openspec/changes/secure-cicd-pipeline/tasks.md` — sección 6 (6.1–6.3).
- `openspec/changes/secure-cicd-pipeline/design.md` — D5 (scripts sobre inline Jenkins) y riesgos (TRIVY_* overrides, WIF operator-side).
- Referencia de HELP (consultable): `scripts/run-trivy.sh` y `scripts/publish.sh` de REQUISITOS YA MERGEADOS (estilo, env vars, exit codes). El Jenkinsfile los CONSUME, no los modifica.

## PERMITIDOS

- `Jenkinsfile` (nuevo) — el pipeline declarativo.
- `scripts/` — SOLO si estrictamente necesitas un helper de metadata/trazabilidad nuevo (p. ej. `scripts/build-metadata.sh`). Justificalo; si podés hacer la metadata desde el Jenkinsfile, no agregues scripts.
- `.gitignore` — solo si hace falta.
- `docs/agent-contract/req5-cicd-pipeline.md` — PROHIBIDO tocarlo.

## NUNCA (prohibido tocar)

- `openspec/**`, `src/`, `tests/`, `Dockerfile`, `requirements*.txt`, `README.md`.
- `scripts/run-trivy.sh`, `scripts/_trivy_html.tmpl`, `scripts/publish.sh`.
- Contratos previos (`docs/agent-contract/req1|2|3|4-*.md`).

## Contrato de interfaz (lo que debe producir)

`Jenkinsfile` — pipeline declarativo (`pipeline { }`), con agent, stages ordenados y fail-fast:

1. **Stage Checkout & Lint** → `python -m flake8` (y/o `pytest` en el mismo o siguiente stage).
2. **Stage Validation / Unit tests** → `python -m pytest`.
3. **Stage Build** → `docker build` (podman-compatible o docker) de la imagen; pasar build-args de trazabilidad OCI (`GIT_SHA`, `REPO_URL`, `BUILD_TIMESTAMP`).
4. **Stage Security Scan** → [EXISTENTE] `scripts/run-trivy.sh <imaagen>` + persist ARTEfactos: `reports/trivy-image.json`, `.html`, y `trivy-fs.*`.
5. **Stage Publish** → [EXISTENTE] `scripts/publish.sh` (dry-run o real según env). NO debe correr real en PRs; el gate real queda a criterio del operador (env) — documentarlo.
6. **Trazabilidad de build (task 6.3)**: un `archiveArtifacts` de metadata (commit SHA + build URL + digests producidos). Se puede generar un `build-metadata.json`/`.txt` en el stage Build o Scan con `GIT_SHA`, `BUILD_URL`, y digests (que el Security Scan ya produce).
7. **Secretos**: NUNCA credenciales estáticas en el Jenkinsfile; toda cred a `withCredentials` de Jenkins secrets / env del operador. Sin logs de secretos.

Requisitos técnicos:
- El `Jenkinsfile` debe ser **validable localmente** con `yamllint`/lint declarativo si existe en el entorno; si NO existe herramienta, se valida por sintaxis YAML-strict (parsear el bloque con un parser YAML tolerante a la sintaxis de Groovy `pipeline { }` es complejo: entonces la verificación será estructural: `grep` de stages ordenados, presencia de `stage('')`, `failFast`, `archiveArtifacts`, etc. + `bash -n` de los scripts que llama).
- Los scripts EXISTENTES se consumen tal cual (estilo y env): `scripts/run-trivy.sh` (args: image; gate CRITICAL/HIGH; genera reports/) y `scripts/publish.sh` (env-driven; semver desde git tag; dry-run).
- Documentación `code-doc-standard` según aplique a archivos nuevos.

## Entorno de verificación

- **Sin Jenkins real.** `act`, `yamllint`, `jenkins-linter` NO están instalados (chequeado). La verificación será:
  1. `bash -n` sobre cualquier script nuevo.
  2. Validación estructural del Jenkinsfile: etapas en orden exacto (lint→tests→build→scan→publish), `failFast`, `archiveArtifacts`, `withCredentials` correcto, no secretos.
  3. Si `yamllint` no existe, intentar parsear el bloque declarativo con un parser YAML (el `pipeline {}` no es YAML puro; documentar la limitación y validar por estructura Groovy declarativa con `grep`/checks).
  4. Regresión pytest/flake8 (no edites tests).
  5. `openspec validate`.
  6. GATE DE SECRETOS final: grep del Jenkinsfile + diff por `GCP_SA_KEY`, `BEGIN.*PRIVATE KEY`, tokens, `password`/`secret` literales.
- **NO hay que ejecutar un Jenkins real ni correr los stages.** Publish real queda fuera de scope (env operator-side).

## DoD

- [ ] `Jenkinsfile` declarativo con los 5 stages en orden y fail-fast (`failFast` o `when`-fail por stage).
- [ ] Stage Security Scan consume `scripts/run-trivy.sh` y archiva reports; Stage Publish consume `scripts/publish.sh`.
- [ ] Trazabilidad: artifact de metadata con commit SHA + build URL + digests (`build-metadata`).
- [ ] Sin secretos estáticos en el Jenkinsfile (solo `withCredentials`/env).
- [ ] Verificación estructural + `bash -n` de helpers + regresión pytest/flake8 + `openspec validate` OK.
- [ ] No tocas `openspec/` ni scripts mergeados.
- [ ] Commit en `feat/req5-cicd-pipeline` (sin push).

## Reporte final del implementer

```
status: DONE | BLOCKED | NEEDS_CONTEXT
requirement: req5-cicd-pipeline
tests: <N passed / N failed> (<comando>)
verification: <estructural Jenkinsfile / bash -n scripts / pytest / flake8 / openspec validate / secrets-gate>
files: <archivos creados/modificados>
evidence: <checks reales: stages order, archiveArtifacts, metadata artifact, grep secretos limpio; exit codes>
notes: <desviaciones>
```

No pegues diffs largos. Si el entorno bloquea, reportá `BLOCKED` con el error real.