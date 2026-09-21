# Spec de referencia: secure-cicd-pipeline

Repositorio: `nehemias1999/genai-secure-cicd-pipeline` · Fuente de verdad: `openspec/changes/secure-cicd-pipeline/`

## Stack confirmado
- **App:** Python + FastAPI (uvicorn).
- **CI/CD:** Jenkins (Pipeline declarativo, `Jenkinsfile`).
- **Seguridad:** Trivy (escaneo de imagen local, gate en CRITICAL/HIGH).
- **Nube:** GCP Artifact Registry (publish con Workload Identity Federation).
- **Calidad:** flake8 (lint) + pytest (unit tests).

---

## Requisitos (5, disjuntos por archivo)

| # | Req | Capability | Archivos propios | Espec |
|---|-----|-----------|------------------|-------|
| 1 | Scafolding + API | `api` | `src/main.py`, `tests/`, `requirements*.txt`, `.gitignore` | `openspec/changes/secure-cicd-pipeline/specs/api/spec.md` |
| 2 | Imagen multi-stage | `container` | `Dockerfile`, `.dockerignore` | `.../specs/container/spec.md` |
| 3 | Escaneo Trivy | `security-scan` | `scripts/run-trivy.sh`, `reports/` | `.../specs/security-scan/spec.md` |
| 4 | Publish Artifact Registry | `registry-publish` | `scripts/publish.sh` | `.../specs/registry-publish/spec.md` |
| 5 | Pipeline Jenkins | `cicd-pipeline` | `Jenkinsfile`, (usa los scripts) | `.../specs/cicd-pipeline/spec.md` |

## Contratos de verificación por perfil (del skill)
- **App (Python):** `pytest tests/` + `flake8 src/` → evidencia real de salida.
- **Pipeline/CI-CD:** validación de sintaxis del Jenkinsfile / `act` si existe, `bash -n` de scripts.
- **IaC/cloud:** `bash -n` + dry-run local de publish script; **nunca** `gcloud`/`docker push` reales hacia un repo GCP con proyecto real sin tu aprobación.

## Flujo por requisito (SDD)
1. Worktree + branch `feat/<req-id>` desde main.
2. Contrato de asignación `docs/agent-contract/<req-id>.md` (en el worktree).
3. Subagente `implementer` (TDD RED→GREEN, evidencia real).
4. Subagente `requirement-reviewer` (sesión fresca, PASSO/FAIL + evidencia).
5. **⛔ GATE HUMANO** — te presento evidencia con `question`, vos validás o rechazás.
6. PR + merge con `gh` (nunca push directo a main).
7. Pasar al siguiente requisito (solo con tu validación).

Requisito 1: **Scaffolding + API** (`api`). Archivos: `src/main.py`, `tests/test_api.py`, `requirements.txt`, `requirements-dev.txt`, `.gitignore`.

Consideraciones del contrato para Req 1:
- FastAPI con tips de Pydantic: `GET /health` → `200` (no requiere auth), `POST /generate` con body JSON `{prompt}` → devuelve respuesta simulada, y sin `prompt` → `422`.
- Key del LLM por env var `GEMINI_API_KEY`, jamás embebida en código ni imagen.
- TDD: escribir los tests primero (RED), después implementar (GREEN), evidencia real de pytest.

¿Arrancamos con el **Requisito 1**?