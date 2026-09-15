# Local verification — 2026-09-15

Environment: Windows 11, Docker Desktop (engine 29.7.2), image `medical-rag:local` (Python 3.12.14).

## Build and tests

| Check | Result |
|---|---|
| `docker build --target test .` | ruff clean, **22 passed** |
| Runtime image size | **926 MB → 483 MB (−48%)** vs. the previous Dockerfile built from `HEAD` (no build toolchain, no PDF, no `.git` in the image) |
| Dependencies | locked with `uv.lock` (93 packages, linux/amd64), LangChain 1.x, no PyTorch |

## Index artifact

| Check | Result |
|---|---|
| `docker compose up index-build` (first run) | 759 pages → **7,079 chunks**, embedded via HF Inference API in **150.7 s**, version `cc759ae1a093` |
| Same build on the Windows host | identical version hash `cc759ae1a093` (deterministic across environments) |
| Second run | `Index version cc759ae1a093 already exists, skipping build` in **< 1 s** |

## Runtime

| Check | Result |
|---|---|
| Container healthy after `docker compose up -d app` | **~6 s** (index pull + 2 gunicorn workers, chain ready in 0.7 s each) |
| `/healthz`, `/readyz` | 200 / 200 |
| Grounded answers (Gemini `gemini-3.5-flash-lite`) | "symptoms of diabetes", "causes of cataracts" answered from the corpus. The PDF is Volume 2 (C–F), so out-of-range topics get "I don't know". |
| Session history across 2 workers | preserved (shared `FLASK_SECRET_KEY`) |
| XSS probe `<img src=x onerror=alert(1)>` | rendered escaped; no raw `<img` in the page |
| `/metrics` with 2 workers | counters aggregated across workers (multiprocess mode), `rag_index_info{version="cc759ae1a093"}` |
| Container user / filesystem | `uid=10001(app)`; `touch /app/x` → `Read-only file system` |
| Transient init failure (unit test) | chain init retried with capped backoff; liveness stays 200, readiness 503 with the last error |

## Environment issue found while verifying (not a code defect)

Docker builds stalled downloading from PyPI. Root cause:
- This network's **IPv4** route to Fastly (PyPI's CDN) is congested: the host downloaded 2.1 MB in 11–20 s over IPv4 vs 0.45 s over IPv6.
- Docker Desktop containers had no IPv6. After enabling it, they received a **ULA** address (`fda6:…`).
- glibc then follows RFC 6724 and still prefers IPv4, so tools in Debian-based containers (uv, pip, apt) kept using the slow path.

**Fix (local machine only):** Docker Engine config `"ipv6": true, "fixed-cidr-v6": "2001:db8:1::/64"`. After it, the same download inside a BuildKit `RUN` step took 0.41 s.
