import time

import pytest

from app.application import create_app
from app.components.rag import RagAnswer


class StubChain:
    def __init__(self, text="Fever is a raised body temperature.", error=None):
        self.text, self.error = text, error

    def answer(self, question):
        if self.error:
            raise self.error
        return RagAnswer(text=self.text, retrieval_s=0.01, llm_s=0.2, usage={"input_tokens": 10})


def _client(chain_factory):
    app = create_app(chain_factory=chain_factory, secret_key="test")
    holder = app.extensions["rag"]
    deadline = time.time() + 5
    while holder.chain is None and holder.error is None and time.time() < deadline:
        time.sleep(0.01)
    return app.test_client()


def test_health_and_readiness():
    client = _client(StubChain)
    assert client.get("/healthz").status_code == 200
    assert client.get("/readyz").status_code == 200


def test_not_ready_while_chain_loading():
    def slow():
        time.sleep(0.5)
        return StubChain()

    app = create_app(chain_factory=slow, secret_key="test")
    client = app.test_client()
    assert client.get("/readyz").status_code == 503
    assert client.get("/healthz").status_code == 200


def test_transient_init_failure_is_retried_until_ready():
    attempts = []

    def flaky():
        attempts.append(1)
        if len(attempts) < 3:
            raise ConnectionError("Temporary failure in name resolution")
        return StubChain()

    app = create_app(chain_factory=flaky, secret_key="test", init_retry_base_s=0.01)
    client = app.test_client()
    deadline = time.time() + 5
    while client.get("/readyz").status_code != 200 and time.time() < deadline:
        time.sleep(0.02)
    assert client.get("/readyz").status_code == 200
    assert len(attempts) == 3


def test_persistent_init_failure_reports_error_but_stays_alive():
    def broken():
        raise RuntimeError("no index")

    app = create_app(chain_factory=broken, secret_key="test", init_retry_base_s=0.01)
    client = app.test_client()
    deadline = time.time() + 5
    while not (client.get("/readyz").get_json() or {}).get("error") and time.time() < deadline:
        time.sleep(0.02)
    ready = client.get("/readyz")
    assert ready.status_code == 503
    assert "no index" in ready.get_json()["error"]
    # Liveness stays green: the startup probe, not a restart loop, decides when to give up.
    assert client.get("/healthz").status_code == 200


def test_chat_escapes_html_from_user_and_model():
    payload = "<img src=x onerror=alert(1)>"
    client = _client(lambda: StubChain(text=payload))
    resp = client.post("/", data={"prompt": payload}, follow_redirects=True)
    body = resp.get_data(as_text=True)
    assert resp.status_code == 200
    assert "<img" not in body
    assert "&lt;img src=x onerror=alert(1)&gt;" in body


def test_llm_error_returns_502_without_crashing():
    client = _client(lambda: StubChain(error=TimeoutError("gemini timeout")))
    resp = client.post("/", data={"prompt": "What is fever?"})
    assert resp.status_code == 502
    assert "Upstream model error" in resp.get_data(as_text=True)


@pytest.mark.parametrize(
    "metric",
    [
        "http_requests_total",
        "http_request_duration_seconds_bucket",
        "rag_retrieval_duration_seconds_bucket",
        "llm_request_duration_seconds_bucket",
    ],
)
def test_metrics_exposed(metric):
    client = _client(StubChain)
    client.post("/", data={"prompt": "What is fever?"})
    body = client.get("/metrics").get_data(as_text=True)
    assert metric in body


def test_missing_secret_key_is_rejected(monkeypatch):
    monkeypatch.setattr("app.config.config.FLASK_SECRET_KEY", None)
    with pytest.raises(RuntimeError, match="FLASK_SECRET_KEY"):
        create_app(chain_factory=StubChain, secret_key=None)
