# Spec Delta: api

## Purpose

Provides a minimal FastAPI dummy GenAI REST API that exposes health and generation endpoints and reads LLM credentials exclusively from runtime environment variables, never from the container image.

## ADDED Requirements

### Requirement: API health endpoint
The API SHALL expose a `GET /health` endpoint that returns `200 OK` with a JSON body indicating service status without requiring authentication.

#### Scenario: Health check returns healthy
- **WHEN** a client requests `GET /health`
- **THEN** the API responds `200 OK`
- **AND** the JSON body contains status information indicating the service is up

### Requirement: API generation endpoint
The API SHALL expose a `POST /generate` endpoint that accepts a JSON payload with a prompt and returns a simulated LLM response. It SHALL NOT make a real external LLM call when it cannot reach the provider.

#### Scenario: Valid prompt returns simulated response
- **WHEN** a client sends `POST /generate` with a JSON body containing a `prompt`
- **THEN** the API responds `200 OK`
- **AND** the JSON body contains the simulated model response for the given prompt

#### Scenario: Missing prompt is rejected
- **WHEN** a client sends `POST /generate` without a `prompt` field
- **THEN** the API responds with `422 Unprocessable Entity`

#### Scenario: Empty prompt is rejected
- **WHEN** a client sends `POST /generate` with an empty string as `prompt`
- **THEN** the API responds with `422 Unprocessable Entity`

#### Scenario: Oversized prompt is rejected
- **WHEN** a client sends `POST /generate` with a `prompt` longer than the configured maximum length
- **THEN** the API responds with `422 Unprocessable Entity`

### Requirement: Structured error responses
The API SHALL return errors in a consistent JSON shape containing an error code and a human-readable message. It SHALL never crash (exit) the process on a request-level failure.

#### Scenario: Client errors are structured JSON
- **WHEN** the API returns a `4xx` error
- **THEN** the response body is a JSON object with an error `code`, a human-readable `message`, and no secret data

#### Scenario: Unexpected failure does not crash the process
- **WHEN** handling a `/generate` request fails unexpectedly (e.g. provider unreachable)
- **THEN** the API returns a `500` response with structured JSON error
- **AND** the process stays alive and a subsequent `GET /health` still succeeds

### Requirement: Runtime credential injection
The API SHALL read the LLM provider API key from an environment variable (e.g. `GEMINI_API_KEY`) at runtime. The API key SHALL NOT be embedded in source code, logs, or the container image.

#### Scenario: API key provided at runtime
- **WHEN** the process is started with the provider API key set as an environment variable
- **THEN** the API is able to reference the key
- **AND** the key value never appears in source files or image layers

#### Scenario: API key absent
- **WHEN** the API starts and generates a response but no provider API key is set
- **THEN** the API still returns a simulated response and SHALL NOT crash or leak any partial credentials