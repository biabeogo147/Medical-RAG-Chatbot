# syntax=docker/dockerfile:1.7

# ---- builder: resolve locked dependencies into /app/.venv ----
# Debian 13 (trixie), pinned by the digest of the multi-platform index, not of one architecture inside it:
# `docker buildx imagetools inspect TAG` prints it on the `Digest:` line (Jenkins guide step 13).
FROM ghcr.io/astral-sh/uv:python3.12-trixie-slim@sha256:9a59bb7206905ccaae4f7dab222fbac47c125a21e5fc16f43f427cd6c940ade3 AS builder
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
# Debian 13 (trixie), pinned by index digest. Moving the base is a commit with a visible diff, and the
# scan in step 12 is what says whether it moved the counts.
FROM python:3.12-slim-trixie@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9 AS runtime
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
