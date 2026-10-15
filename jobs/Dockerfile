FROM python:3.12-slim-bookworm AS builder

WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:0.9.26 /uv /usr/local/bin/uv
ENV UV_PYTHON_DOWNLOADS=0 \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1

COPY pyproject.toml uv.lock ./
RUN uv sync --locked --only-group jobs --no-install-project --no-cache

FROM python:3.12-slim-bookworm

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

RUN useradd --uid 10001 --no-create-home app
COPY --from=builder /app/.venv /app/.venv
COPY jobs/create_pdfs.py jobs/analyze_pdfs.py jobs/sample.pdf ./

USER app

# Each Container Apps job sets its own command, which replaces this CMD. If a
# job start override drops the command, fail loudly instead of letting the
# base image's bare `python` exit 0 and report success.
CMD ["python", "-c", "import sys; sys.exit('No command set: start the job with --command python <script>.py')"]
