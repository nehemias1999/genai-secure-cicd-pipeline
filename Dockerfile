# syntax=docker/dockerfile:1
# ==============================================================================
# Description: Imagen multi-stage para la API GenAI dummy. Stage builder instala
#   deps runtime pinneadas; stage runtime copia solo artefactos, usuario non-root
#   (UID 10001), labels OCI de trazabilidad (revision, source, created).
# Author: implementer-req2 (SDD flow, requisito container)
# Usage: docker build --build-arg GIT_SHA=... --build-arg REPO_URL=... --build-arg BUILD_TIMESTAMP=... -t <name>:<tag> .
# Env Vars (build args): GIT_SHA, REPO_URL, BUILD_TIMESTAMP
# Dependencies: python:3.12.6-slim-bookworm (base), requirements.txt (pinned)
# ==============================================================================
# =============================================================================
# Stage 1: builder — instala las dependencias runtime pinneadas
# -----------------------------------------------------------------------------
# Reproducibilidad: tag completo python:3.12.6-slim-bookworm (patch pinneado,
# inmutable en docker-library) + versions pinneadas en requirements.txt.
# Las dev deps (pytest/flake8, requirements-dev.txt) NUNCA entran a este stage.
# =============================================================================
FROM python:3.12.6-slim-bookworm AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Copia SOLO el manifiesto de deps: cualquier cambio en requirements.txt
# invalida unicamente este layer (cache eficiente en builds repetidos).
COPY requirements.txt requirements.txt

# --target: instala en un dir plano para copiar site-packages al runtime.
# --no-cache-dir: sin pip cache (tambien garantiza cache ausente en runtime).
RUN pip install --no-cache-dir --target /app/deps -r requirements.txt

# =============================================================================
# Stage 2: runtime — imagen final minima, non-root, solo artefactos necesarios
# =============================================================================
FROM python:3.12.6-slim-bookworm

# Build args para trazabilidad OCI, resueltos por el pipeline/local con
# valores reales; default vacio para que `docker build` sin args funcione.
ARG GIT_SHA=""
ARG REPO_URL=""
ARG BUILD_TIMESTAMP=""

LABEL org.opencontainers.image.title="genai-secure-api" \
      org.opencontainers.image.description="GenAI dummy API packaged by the secure CI/CD pipeline" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.created="${BUILD_TIMESTAMP}" \
      org.opencontainers.image.base.name="python:3.12.6-slim-bookworm"

# PYTHONPATH: /app/deps (site-packages del builder) y /app/src (modulo main).
ENV PYTHONPATH=/app/deps:/app/src \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Solo lo necesario: deps ya resueltas + codigo de la app.
COPY --from=builder /app/deps /app/deps
COPY src/ /app/src/

# Usuario no privilegiado (UID 10001, > 1000) creado en build; el proceso
# jamas corre como root. Sin HOME para minimizar superficie.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser \
    && chown -R appuser:appuser /app

USER appuser

EXPOSE 8000

# /health nativo (el slim image no trae curl).
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status==200 else 1)"

# `python -m` garantiza que cwd (/app) este en sys.path; main:app resuelve
# via PYTHONPATH=/app/src.
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]