# syntax=docker/dockerfile:1.7

# ---- builder: resolve locked dependencies into /app/.venv ----
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-dev --no-install-project

# ---- test: lint + unit tests (docker build --target test .) ----
FROM builder AS test
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-install-project
COPY pyproject.toml gunicorn.conf.py ./
COPY src ./src
COPY tests ./tests
RUN .venv/bin/ruff check src tests && .venv/bin/pytest -q

# ---- runtime ----
FROM python:3.12-slim-bookworm AS runtime
ENV PATH=/app/.venv/bin:$PATH \
    PYTHONPATH=/app/src \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/tmp/hf \
    INDEX_DIR=/tmp/index \
    PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
    && mkdir /index-store && chown app:app /index-store
WORKDIR /app
COPY --from=builder /app/.venv /app/.venv
COPY src ./src
COPY gunicorn.conf.py ./
COPY --chmod=0755 scripts/start.sh ./start.sh
USER 10001
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"
CMD ["./start.sh"]
