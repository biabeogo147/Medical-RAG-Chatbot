import os
import threading
import time

from flask import Flask, Response, g, jsonify, redirect, render_template, request, session, url_for
from markupsafe import Markup, escape
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    REGISTRY,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    multiprocess,
)

from app.common.logger import get_logger
from app.config import config

logger = get_logger(__name__)

MAX_HISTORY = 20
LATENCY_BUCKETS = (0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 32)

HTTP_REQUESTS = Counter("http_requests_total", "HTTP requests", ["route", "method", "status"])
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP request latency", ["route"], buckets=LATENCY_BUCKETS
)
RETRIEVAL_LATENCY = Histogram(
    "rag_retrieval_duration_seconds", "Vector retrieval latency", buckets=LATENCY_BUCKETS
)
LLM_LATENCY = Histogram(
    "llm_request_duration_seconds", "LLM call latency", ["model", "outcome"], buckets=LATENCY_BUCKETS
)
INDEX_INFO = Gauge(
    "rag_index_info", "Loaded index version (value is always 1)", ["version"], multiprocess_mode="max"
)


def nl2br(value: str) -> Markup:
    # Escape first: LLM output and user input must never be rendered as HTML.
    return Markup("<br>\n").join(escape(value).split("\n"))


class ChainHolder:
    """Builds the RAG chain per worker in the background so /healthz answers immediately.

    Failures are retried with capped exponential backoff: a transient error at boot (DNS, HF API)
    must not leave the worker unready forever, and liveness must not restart-loop on it either.
    """

    def __init__(self, factory, retry_base_s: float = 1.0, retry_max_s: float = 30.0):
        self.chain = None
        self.error: str | None = None
        self._factory = factory
        self._retry_base_s = retry_base_s
        self._retry_max_s = retry_max_s

    def start(self):
        threading.Thread(target=self._load, name="chain-loader", daemon=True).start()

    def _load(self):
        started = time.monotonic()
        delay = self._retry_base_s
        attempt = 0
        while self.chain is None:
            attempt += 1
            try:
                self.chain = self._factory()
                self.error = None
                logger.info("RAG chain ready in %.1fs (attempt %d)", time.monotonic() - started, attempt)
            except Exception as exc:
                self.error = f"{type(exc).__name__}: {exc}"
                logger.warning(
                    "RAG chain init attempt %d failed (%s); retrying in %.1fs", attempt, self.error, delay
                )
                time.sleep(delay)
                delay = min(delay * 2, self._retry_max_s)


def _index_version() -> str:
    manifest = config.INDEX_DIR / "manifest.json"
    if manifest.exists():
        import json

        return json.loads(manifest.read_text(encoding="utf-8")).get("version", "unknown")
    return "unknown"


def _metrics_payload() -> bytes:
    if os.getenv("PROMETHEUS_MULTIPROC_DIR"):
        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
        return generate_latest(registry)
    return generate_latest(REGISTRY)


def create_app(chain_factory=None, secret_key: str | None = None, init_retry_base_s: float = 1.0) -> Flask:
    app = Flask(__name__)
    app.secret_key = secret_key or config.FLASK_SECRET_KEY
    if not app.secret_key:
        raise RuntimeError("FLASK_SECRET_KEY is not set")
    app.jinja_env.filters["nl2br"] = nl2br

    if chain_factory is None:
        from app.components.rag import build_chain as chain_factory
    holder = ChainHolder(chain_factory, retry_base_s=init_retry_base_s)
    holder.start()
    app.extensions["rag"] = holder

    @app.before_request
    def _start_timer():
        g.started = time.perf_counter()

    @app.after_request
    def _record(response):
        route = request.url_rule.rule if request.url_rule else "unmatched"
        if route != "/metrics":
            HTTP_REQUESTS.labels(route, request.method, str(response.status_code)).inc()
            HTTP_LATENCY.labels(route).observe(time.perf_counter() - g.started)
        return response

    @app.get("/healthz")
    def healthz():
        return jsonify(status="ok")

    @app.get("/readyz")
    def readyz():
        if holder.chain is None:
            return jsonify(status="not ready", error=holder.error), 503
        return jsonify(status="ready")

    @app.get("/metrics")
    def metrics():
        return Response(_metrics_payload(), mimetype=CONTENT_TYPE_LATEST)

    @app.route("/", methods=["GET", "POST"])
    def index():
        messages = session.get("messages", [])
        if request.method == "GET":
            return render_template("index.html", messages=messages)

        user_input = (request.form.get("prompt") or "").strip()
        if not user_input:
            return redirect(url_for("index"))
        if holder.chain is None:
            return render_template(
                "index.html", messages=messages, error="The assistant is still starting up."
            ), 503

        messages.append({"role": "user", "content": user_input})
        attempt_started = time.perf_counter()
        try:
            result = holder.chain.answer(user_input)
        except Exception as exc:
            LLM_LATENCY.labels(config.MODEL_NAME, "error").observe(time.perf_counter() - attempt_started)
            logger.exception("RAG answer failed")
            session["messages"] = messages[-MAX_HISTORY:]
            return render_template(
                "index.html", messages=messages, error=f"Upstream model error: {type(exc).__name__}"
            ), 502

        RETRIEVAL_LATENCY.observe(result.retrieval_s)
        LLM_LATENCY.labels(config.MODEL_NAME, "ok").observe(result.llm_s)
        messages.append({"role": "assistant", "content": result.text})
        session["messages"] = messages[-MAX_HISTORY:]
        return redirect(url_for("index"))

    @app.get("/clear")
    def clear():
        session.pop("messages", None)
        return redirect(url_for("index"))

    INDEX_INFO.labels(_index_version()).set(1)
    return app
