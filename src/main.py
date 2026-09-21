"""GenAI dummy API.

Exposes a health endpoint and a simulated generation endpoint. The LLM
provider API key is read exclusively from the runtime environment, never
embedded in the source code.
"""

import os
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from starlette.exceptions import HTTPException as StarletteHTTPException

MAX_PROMPT_LENGTH = 500


def _error_body(
    code: str, message: str, details: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Build the structured error body `{"error": {...}}`."""
    return {
        "error": {"code": code, "message": message, "details": details or {}}
    }


async def structured_http_error_handler(
    request: Request, exc: StarletteHTTPException
) -> JSONResponse:
    """Return structured JSON for HTTP errors raised by handlers (4xx/5xx)."""
    detail = exc.detail
    if isinstance(detail, dict) and "code" in detail:
        body = _error_body(
            detail["code"], detail["message"], detail.get("details", {})
        )
    else:
        body = _error_body("http_error", str(detail))
    return JSONResponse(status_code=exc.status_code, content=body)


async def unhandled_exception_handler(
    request: Request, exc: Exception
) -> JSONResponse:
    """Map any unhandled exception to a structured 500; process stays alive."""
    return JSONResponse(
        status_code=500,
        content=_error_body("internal_error", "Internal server error"),
    )


# Handlers are supplied at construction time so they participate in the
# ServerErrorMiddleware/ExceptionMiddleware stack built during __init__.
app = FastAPI(
    exception_handlers={
        StarletteHTTPException: structured_http_error_handler,
        Exception: unhandled_exception_handler,
    }
)


class GenerateRequest(BaseModel):
    """Request payload for POST /generate."""

    prompt: str


def get_api_key() -> str | None:
    """Read the LLM provider API key from the runtime environment."""
    return os.environ.get("GEMINI_API_KEY")


def generate_simulated_response(prompt: str) -> str:
    """Return a deterministic simulated response without calling an LLM."""
    return f"Echo: {prompt}"


@app.get("/health")
def health() -> dict[str, str]:
    """Return service status without requiring authentication."""
    return {"status": "ok"}


@app.post("/generate")
def generate(payload: GenerateRequest) -> dict[str, str]:
    """Return a simulated deterministic response for the given prompt."""
    prompt = payload.prompt
    if not prompt:
        raise HTTPException(
            status_code=422,
            detail={
                "code": "invalid_prompt",
                "message": "prompt must not be empty",
            },
        )
    if len(prompt) > MAX_PROMPT_LENGTH:
        raise HTTPException(
            status_code=422,
            detail={
                "code": "invalid_prompt",
                "message": f"prompt exceeds {MAX_PROMPT_LENGTH} characters",
            },
        )
    return {"response": generate_simulated_response(prompt)}
