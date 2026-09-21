# Contrato de asignación — Requisito 4: registry-publish

## Contexto

Proyecto: `genai-secure-cicd-pipeline` (DevOps showcase). Cambio OpenSpec: `secure-cicd-pipeline`.
Ya entregados en `main`: Req 1 (api), Req 2 (container), Req 3 (security-scan).

Este requisito implementa el etiquetado semver + `latest` de la imagen y la publicación a GCP
Artifact Registry con Workload Identity Federation (nunca credenciales estáticas).

## Spec de referencia (leer)

- `openspec/changes/secure-cicd-pipeline/specs/registry-publish/spec.md` — criterios de aceptación (fuente de verdad).
- `openspec/changes/secure-cicd-pipeline/tasks.md` — sección 5 (5.1–5.3).
- `openspec/changes/secure-cicd-pipeline/design.md` — decisiones D4 (WIF, env-driven) y D5 (scripts sobre inline Jenkins) + riesgos sobre semver.

## PERMITIDOS

- `scripts/publish.sh` (nuevo) — script de publish.
- `.gitignore` — solo si hace falta una línea nueva (evita ruido).
- `docs/agent-contract/req4-registry-publish.md` — PROHIBIDO tocarlo.

## NUNCA (prohibido tocar)

- `openspec/**` — spec, jamás.
- `src/`, `tests/`, `Dockerfile`, `requirements*.txt`, `Jenkinsfile`, `README.md`.
- `scripts/run-trivy.sh`, `scripts/_trivy_html.tmpl`, otros contratos (`docs/agent-contract/*`).

## Contrato de interfaz (lo que debe producir)

`scripts/publish.sh` — script bash ejecutable (`chmod +x`), con:

- **Variables de entorno** (no argumentos; provienen del pipeline/operador):
  - `IMAGE` (obligatorio): nombre de la imagen sin tag, p. ej. `genai-secure-api`.
  - `REGISTRY_HOST` o compose the full repo? Usar convención del design D4:
    target = `$REGION-docker.pkg.dev/$PROJECT_ID/$REGISTRY_REPO/$IMAGE`.
    Variables del operador: `REGION` (p. ej. `us-central1`), `PROJECT_ID`, `REGISTRY_REPO` (repo AR), `IMAGE`.
  - `GIT_TAG` (opcional, default `git describe --tags --exact-match`): el tag semver `vX.Y.Z` a publicar. Si no se pasa y el commit actual no tiene tag válido → **falla con mensaje claro**.
  - `GOOGLE_APPLICATION_CREDENTIALS` (opcional): ruta al archivo de credenciales federadas (WIF `--cred-file`) o env `CI_IAM_CREDENTIALS_FILE`. Si existe, se usa. Si no existe, publish DEBE fallar de forma segura.
- **Comportamiento**:
  1. **Resolución de versión**: valida el patrón `^v?[0-9]+\.[0-9]+\.[0-9]+$` (acepta `v` prefijo; canonicaliza a `vX.Y.Z`). Sin tag válido → exit non-zero + mensaje claro, y NO marca publicado.
  2. **Tag local**: etiqueta la imagen LOCAL con `$IMAGE:$VER` y `$IMAGE:latest` usando el runtime de contenedor disponible (podman o docker). Verifica que AMBOS tags apuntan al MISMO digest local (`podman inspect --format '{{.Id}}'` / login-less digest comparison).
  3. **Push**: usa `docker push`/`podman push` hacia el target AR compuesto. Autenticación solo vía credenciales federadas (env `GOOGLE_APPLICATION_CREDENTIALS`/`CI_IAM_CREDENTIALS_FILE` → `gcloud auth login --cred-file` si gcloud existe; si no hay credenciales, FAIL seguro).
  4. **Apropiado para CI**: nunca guarda credenciales en el repo; si faltan env vars de registry → exit non-zero con mensaje claro (NO push silencioso).
  5. Log de cada paso a stdout/stderr distinguibles.
- **Modo seguro (key para verificar localmente)**: en el entorno de desarrollo sin credenciales reales, el script DEBE poder ejecutarse en un "dry-run" que valide la lógica de tag/resolución/semver y el chequeo de digests SIN hacer push real, y DEBE fallar limpiamente (exit ≠ 0, mensaje claro) cuando faltan credenciales/registry — sin tocar la red ni registros.
- Documentación `code-doc-standard` obligatoria en el header (propósito, usage, env vars, salidas/exit codes).

## Entorno de verificación (leer y respetar)

- **Runtime**: podman 6.1.2 (docker es shim de podman). `gcloud` NO está instalado → toda la verificación local es dry-run y lógica pura.
- **NO hay accounts/credenciales GCP en este entorno. NO hagas push real a ningún registro, NO crees credenciales, NO uses `terraform apply`.** Toda verificación de publish es lógica dry-run (resolución semver, tags locales, chequeo digest, fallo limpio ante falta de env).
- Uso de red: `git` a GitHub está OK (push de branch); NO se necesita red para el publish.
- La imagen local para las pruebas: `podman build -t genai-secure-api:req4-test .` en la raíz.
- Puedes crear un git TAG local de prueba (`git tag v1.2.3 -m "test"`) en el worktree para validar la resolución de versión; NO lo pushees si no quieres (o borralo después). El tag no entra al commit.

## Comandos de verificación (debes correrlos y adjuntar salida real)

1. `bash -n scripts/publish.sh`
2. `shellcheck scripts/publish.sh` si está instalado (si no, anótalo)
3. Regresión: `python3 -m pytest` y `python3 -m flake8` en la raíz (no los edites)
4. `podman build -t genai-secure-api:req4-test .`
5. Tag local de prueba `v1.2.3` en el HEAD actual → correr `scripts/publish.sh --dry-run` (o el flag/var que definas) y verificar: resolves 1.2.3, crea tags local `v1.2.3` y `latest` apuntando al mismo digest, y para antes del push (no toca red) — con mensaje claro si falta credencial.
6. Sin tag válido (después de quitar el tag de prueba): corrida → exit ≠ 0 + mensaje claro "no tag semver".
7. Sin env vars de registry/credenciales: corrida → exit ≠ 0 + mensaje claro.
8. `openspec validate` en el worktree.

## DoD

- [ ] `scripts/publish.sh` existe, `chmod +x`, documentado (`code-doc-standard`).
- [ ] `bash -n` pasa; shellcheck limpio si está disponible.
- [ ] Resolución semver `vX.Y.Z` + `latest` con digest idéntico verificado (evidencia).
- [ ] Sin tag válido → exit ≠ 0, sin publish, mensaje claro (evidencia).
- [ ] Faltan env vars/credenciales → exit ≠ 0, sin publish, sin salida ambigua (evidencia).
- [ ] Nunca push real a un registro durante la verificación.
- [ ] No tocas `openspec/`, no rompes pytest/flake8.
- [ ] Sin secretos en el diff (grep `GCP_SA_KEY`, `BEGIN.*PRIVATE KEY`, tokens).
- [ ] `openspec validate` OK.

## Reporte final del implementer

```
status: DONE | BLOCKED | NEEDS_CONTEXT
requirement: req4-registry-publish
tests: <N passed / N failed> (<comando>)
verification: <bash -n / shellcheck / podman build / semver+tag+digest / dry-run fail-no-tag / fail-no-env / reconfirm>
files: <archivos creados/modificados>
evidence: <outputs reales cortos: exit codes, digests>
notes: <desviaciones>
```

No pegues diffs ni volcados largos. Si el entorno bloquea (red, permisos) reportá `BLOCKED` con el error real; no improvises un trabajo a medias.