# Agent Contract — req1-api

## Spec section (fuente de verdad — SOLO LECTURA)

- Spec: `openspec/changes/secure-cicd-pipeline/specs/api/spec.md` (en el worktree).
- No modifiques ningún archivo bajo `openspec/`.

## Alcance (PERMITIDOS)

- `src/main.py` — aplicación FastAPI.
- `tests/test_api.py` — tests unitarios.
- `tests/__init__.py` — paquete de tests (o método equivalente para que pytest resuelva).

## Scope del Req 1

Scaffolding mínimo del proyecto Python + implementación de la API:

- `requirements.txt` con deps runtime pinneadas: `fastapi`, `uvicorn`.
- `requirements-dev.txt` con deps dev pinneadas: `pytest`, `httpx`, `flake8`.
- `.gitignore` (mínimo: `__pycache__/`, `.pytest_cache/`, `.venv/`, `reports/`, `.worktrees/`, `.env`).
- `src/main.py` con la API.
- `tests/test_api.py` con tests unitarios.

## Interface / API contract

Implementación FastAPI sobre `src/main.py` con módulo `main`:

**`GET /health`** → `200 OK`, body JSON: `{"status": "ok"}`.
- Sin autenticación.
- `tests/test_api.py`: `test_health_returns_ok`.

**`POST /generate`** → body JSON request `{"prompt": str}`.
- `200 OK` con body JSON `{"response": "<mensaje simulado>"}` (determinístico acorde al prompt, ej. `"Echo: <prompt>"`). No hace ninguna llamada real a un LLM.
- `422 Unprocessable Entity` cuando:
  - falta el campo `prompt` (Pydantic lo maneja automáticamente).
  - `prompt` es string vacío `""`.
  - `prompt` supera `MAX_PROMPT_LENGTH` (500 caracteres).
- Validación explícita en el handler: string vacío/oversize → raise `HTTPException(422)` para que el body de error sea estructurado.
- `tests/test_api.py`: `test_generate_returns_response`, `test_generate_missing_prompt_422`, `test_generate_empty_prompt_422`, `test_generate_oversized_prompt_422`.

**Error handler global** — si un handler lanza una excepción no manejada (p.ej. `RuntimeError` por un "proveedor inalcanzable"), el API responde `500` con JSON estructurado `{"error": {"code": "internal_error", "message": ...}}` y **el proceso no se termina** (no `raise SystemExit`, no crash). Un `GET /health` posterior sigue respondiendo `200`.
- `tests/test_api.py`: `test_internal_error_returns_structured_500`, `test_process_survives_internal_error` (health ok tras forzar error interno).

**Formato de error estructurado (4xx y 5xx)** — body JSON:
```json
{"error": {"code": "string", "message": "human readable", "details": {}}}
```
- Para `422` de Pydantic se preserva el body de FastAPI (estándar) PERO se añade un handler específico para el caso manual; mantener coherencia: si el `422` es de Pydantic, FastAPI genera su propio formato — NO sobre-escribas eso. El contrato exige formato estructurado en nuestros errores manuales (empty/oversize → 422 con `{"error":{...}}`) y en el 500 global.
- El campo `message` jamás contiene datos secretos.

**Credenciales runtime** — la API SHALL leer `GEMINI_API_KEY` de env var en runtime. No embebas ningún valor en código. Si no está seteada, la API responde normalmente (respuesta simulada) sin crashear.

**Config** — constante `MAX_PROMPT_LENGTH = 500` y lectura de `GEMINI_API_KEY` desde `os.environ` (podés usar un pequeño módulo de config o pydantic-settings si lo preferís, pero mantenelo simple).

**Package**: `app = FastAPI()` en `src/main.py`, inyectable vía `create_app()` o import directo. Tests usan `TestClient` de `fastapi.testclient` (requiere `httpx`).

## Never touch

- `openspec/**` (fuente de verdad, solo lectura).
- `Dockerfile`, `.dockerignore`, `scripts/`, `Jenkinsfile` (requisitos futuros).
- No modifiques otros tests.
- No commitees.

## Perfil de proyecto

**App (Python)** — comandos de verificación:

```
cd <worktree>/req1-api
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest tests/ -q          # todos GREEN
flake8 src/
```

Evidencia: salida real de `pytest` (test PASSED, exit 0) y `flake8` limpio.

## DoD verificable

- `pytest tests/ -q` → todos los tests pasan (exit 0), incluidos los nuevos.
- `flake8 src/` → exit 0 sin errores.
- Cobertura funcional de todos los escenarios de `api/spec.md`.
- Tests escritos en orden TDD: tests primero (RED si corres el test antes de la implementación), luego implementación GREEN.
- El API no embebe credenciales (grep por `GEMINI_API_KEY` en `src/` solo encuentra la lectura de `os.environ`, no un valor).

## Formato de reporte del implementer

- Estado: `DONE | BLOCKED | NEEDS_CONTEXT`.
- Archivos tocados (lista con paths).
- Evidencia real: output de pytest y flake8 (exit codes).
- Nota: qué escenarios de la spec cubren los tests.