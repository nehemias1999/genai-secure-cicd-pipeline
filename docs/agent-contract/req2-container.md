# Agent Contract — req2-container

## Spec section (fuente de verdad — SOLO LECTURA)

- Spec: `openspec/changes/secure-cicd-pipeline/specs/container/spec.md` (en el worktree).
- No modifiques ningún archivo bajo `openspec/`.

## Alcance (PERMITIDOS)

- `Dockerfile` — build multi-stage (builder → runtime), usuario non-root final.
- `.dockerignore` — excluye caches, venv, reports, docs, .git, worktrees.

## Scope del Req 2

Packaging seguro de la app `src/main.py` (ya existe en main) en imagen Docker multi-stage:

- **Stage builder** (base `python:3.12-slim`): instala deps runtime desde `requirements.txt`, prepara las deps. NO instala dev deps (pytest/flake8 no entran en la imagen).
- **Stage runtime** (base `python:3.12-slim`): copia app + deps desde builder, crea usuario `appuser` non-root, ejecución como non-root, entrypoint/CMD que corre uvicorn.
- **`.dockerignore`** con al menos: `.git`, `.venv`, `__pycache__`, `*.pyc`, `.pytest_cache`, `reports`, `docs`, `.worktrees`.
- **Deps pinneadas**: usás `requirements.txt` existente (fastapi/uvicorn pinneados). El copy de deps usa `--require-hashes`? NO — solo pip install a un target dir dentro del builder para copiar site-packages a runtime.
- **Labels OCI** (trazabilidad): en el runtime stage, `org.opencontainers.image.revision` (build arg `GIT_SHA`), `org.opencontainers.image.source` (build arg `REPO_URL`), `org.opencontainers.image.created` (build arg `BUILD_TIMESTAMP`). Build args con default vacío, resueltos por el pipeline/local con valores reales.

## Interface / contract

**CIFRAS CLAVE (requisito de reproducibilidad):**
- Base images: `python:3.12-slim` en ambos stages (pinnea tag completo, ej. `python:3.12-slim-bookworm` o `python:3.12.6-slim-bookworm` — lo que haya disponible; elegí una tag digest-pinneable si es factible o documentá).
- La imagen final corre como `appuser` (UID arbitrario > 1000, ej. 10001), nunca root.
- `WORKDIR /app`; runtime expone el puerto que usa uvicorn (default `8000`).
- `EXPOSE 8000`; `CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]` (o equivalente con el paquete correcto; recordá que `src/main.py` define `app` en módulo `main`).
- Librerías instaladas de forma reproducible: `pip install --no-cache-dir --target /app/deps -r requirements.txt` en builder; runtime copia `/app/deps` y setea `PYTHONPATH`/`sys.path` adecuado, o usa `pip install` clásico en builder y copia los site-packages — elegí el enfoque más simple que mantenga la imagen final sin dev deps.

**Cómo verificar la imagen final (perfil App/container, en el worktree):**
```
docker build --build-arg GIT_SHA=$(git rev-parse --short HEAD) \
             --build-arg REPO_URL=https://github.com/nehemias1999/genai-secure-cicd-pipeline \
             --build-arg BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
             -t genai-secure-api:req2 .
docker run --rm genai-secure-api:req2 id -u        # debe imprimir 10001 (no 0)
docker run --rm genai-secure-api:req2 sh -c "python -c 'import fastapi, sys; print(\"ok\")'"  # import ok sin dev deps
docker inspect genai-secure-api:req2 --format '{{json .Config.Labels}}' | python3 -m json.tool   # labels OCI presentes
```
- Multi-stage: verificá con `docker history` o builds logs que el runtime stage no tenga pip cache / dev deps. Dev deps: la imagen final NO debe contener `pytest` ni `flake8` (verificá con `docker run --rm genai-secure-api:req2 sh -c "python -c 'import pytest'"` → debe fallar).

## Never touch

- `openspec/**` (solo lectura).
- `src/`, `tests/`, `requirements*.txt` (ya entregados y verdes en main).
- `scripts/`, `Jenkinsfile` (requisitos futuros).
- No modifiques otros tests. No commitees.

## Perfil de proyecto

**Container / App** — comandos de verificación: los de arriba (docker build + run + inspect). Evidencia: salidas reales de `docker build` (success), `docker run` (UID 10001, imports ok, ausencia de dev deps) y `docker inspect` (labels).

## DoD verificable

- `docker build` con los build args → exit 0, y el runtime stage es multi-stage (la imagen final es chica, tipo "slim").
- `docker run` → proceso corre como non-root (UID != 0).
- La imagen NO contiene `pytest`/`flake8` (import falla) ni pip cache.
- `docker inspect` → labels OCI con `revision`, `source`, `created`.
- La imagen levanta la API: `docker run -p 8000:8000` y `curl localhost:8000/health` responde `{"status":"ok"}` (montando la app correctamente).
- Si no hay Docker disponible en el entorno, reportá BLOCKED con el error exacto (no inventes evidencia).

## Formato de reporte del implementer

- Estado: `DONE | BLOCKED | NEEDS_CONTEXT`.
- Archivos creados/modificados.
- Evidencia real: salida de docker build (stage de salidas relevantes), docker run (UID), docker inspect (labels JSON), curl health.
- Nota: qué escenarios de container/spec.md se cubren.