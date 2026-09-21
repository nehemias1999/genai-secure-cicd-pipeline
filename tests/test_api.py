"""Unit tests for the GenAI dummy API (requirement `api`).

Covers every scenario in openspec/changes/secure-cicd-pipeline/specs/api/spec.md:

- Health check returns healthy.
- Valid prompt returns simulated response.
- Missing / empty / oversized prompt is rejected with 422.
- Client errors are structured JSON.
- Unexpected failure does not crash the process (500 structured + health alive).
- API key read from runtime environment; simulated response when absent.
"""

import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

# Make the `src` package importable as plain module `main` without installing.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import main as app_module  # noqa: E402
from main import MAX_PROMPT_LENGTH, app, get_api_key  # noqa: E402


@pytest.fixture(scope="module")
def client() -> TestClient:
    """TestClient bound to the FastAPI app under test."""
    return TestClient(app)


@pytest.fixture(scope="module")
def resilient_client() -> TestClient:
    """TestClient that does not re-raise server exceptions, like a real client.

    Starlette's ServerErrorMiddleware responds with the registered 500 handler
    and then re-raises the exception; a plain TestClient would propagate it.
    `raise_server_exceptions=False` observes the HTTP response instead, the
    same way an external client (or uvicorn in production) would.
    """
    return TestClient(app, raise_server_exceptions=False)


def test_health_returns_ok(client: TestClient) -> None:
    """GET /health responds 200 OK with a status body, no auth required."""
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_generate_returns_response(client: TestClient) -> None:
    """POST /generate with a valid prompt returns a deterministic echo."""
    response = client.post("/generate", json={"prompt": "hola mundo"})

    assert response.status_code == 200
    body = response.json()
    assert body["response"] == "Echo: hola mundo"


def test_generate_missing_prompt_422(client: TestClient) -> None:
    """POST /generate without a prompt field is rejected (422, Pydantic)."""
    response = client.post("/generate", json={})

    assert response.status_code == 422


def test_generate_empty_prompt_422(client: TestClient) -> None:
    """POST /generate with an empty prompt is rejected with structured 422."""
    response = client.post("/generate", json={"prompt": ""})

    assert response.status_code == 422
    body = response.json()
    assert body["error"]["code"] == "invalid_prompt"
    assert isinstance(body["error"]["message"], str)
    assert body["error"]["details"] == {}


def test_generate_oversized_prompt_422(client: TestClient) -> None:
    """POST /generate with a prompt over MAX_PROMPT_LENGTH is rejected."""
    oversized = "a" * (MAX_PROMPT_LENGTH + 1)
    response = client.post("/generate", json={"prompt": oversized})

    assert response.status_code == 422
    body = response.json()
    assert body["error"]["code"] == "invalid_prompt"
    assert isinstance(body["error"]["message"], str)


def test_internal_error_returns_structured_500(
    resilient_client: TestClient, monkeypatch
) -> None:
    """An unhandled handler exception maps to a structured 500 JSON body."""
    def boom(prompt: str) -> str:
        raise RuntimeError("provider unreachable")

    monkeypatch.setattr(app_module, "generate_simulated_response", boom)

    response = resilient_client.post("/generate", json={"prompt": "boom"})

    assert response.status_code == 500
    body = response.json()
    assert body["error"]["code"] == "internal_error"
    assert isinstance(body["error"]["message"], str)


def test_process_survives_internal_error(
    resilient_client: TestClient, monkeypatch
) -> None:
    """After an internal 500, the process stays alive and /health still works."""
    def boom(prompt: str) -> str:
        raise RuntimeError("provider unreachable")

    monkeypatch.setattr(app_module, "generate_simulated_response", boom)

    error_response = resilient_client.post("/generate", json={"prompt": "boom"})
    assert error_response.status_code == 500

    health_response = resilient_client.get("/health")
    assert health_response.status_code == 200
    assert health_response.json() == {"status": "ok"}


def test_gemini_api_key_reads_from_env(monkeypatch) -> None:
    """The API key is read from GEMINI_API_KEY at runtime, never embedded."""
    monkeypatch.setenv("GEMINI_API_KEY", "test-key-123")

    assert get_api_key() == "test-key-123"


def test_generate_simulated_without_api_key(client: TestClient, monkeypatch) -> None:
    """Without GEMINI_API_KEY the API still returns a simulated response."""
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)

    response = client.post("/generate", json={"prompt": "sin clave"})

    assert response.status_code == 200
    assert response.json()["response"] == "Echo: sin clave"