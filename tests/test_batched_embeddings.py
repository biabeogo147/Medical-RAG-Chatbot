import pytest
from langchain_core.embeddings import Embeddings

from app.components.embeddings import BatchedEmbeddings, is_retryable


class HttpError(Exception):
    def __init__(self, status):
        super().__init__(f"HTTP {status}")
        self.response = type("Resp", (), {"status_code": status})()


class FlakyEmbeddings(Embeddings):
    def __init__(self, failures):
        self.failures = list(failures)
        self.batches = []

    def embed_documents(self, texts):
        if self.failures:
            raise self.failures.pop(0)
        self.batches.append(len(texts))
        return [[float(len(t))] for t in texts]

    def embed_query(self, text):
        return [1.0]


def test_batches_texts_and_preserves_order():
    inner = FlakyEmbeddings([])
    emb = BatchedEmbeddings(inner, batch_size=3, sleep=lambda _: None)
    texts = ["a", "bb", "ccc", "dddd", "eeeee", "ffffff", "g"]
    assert emb.embed_documents(texts) == [[1.0], [2.0], [3.0], [4.0], [5.0], [6.0], [1.0]]
    assert inner.batches == [3, 3, 1]


def test_retries_rate_limit_then_succeeds():
    delays = []
    inner = FlakyEmbeddings([HttpError(429), HttpError(503)])
    emb = BatchedEmbeddings(inner, batch_size=10, base_delay_s=1, sleep=delays.append)
    assert emb.embed_documents(["x"]) == [[1.0]]
    assert len(delays) == 2 and delays[1] > delays[0]


def test_does_not_retry_auth_errors():
    inner = FlakyEmbeddings([HttpError(403)])
    emb = BatchedEmbeddings(inner, sleep=lambda _: pytest.fail("should not sleep"))
    with pytest.raises(HttpError):
        emb.embed_documents(["x"])


def test_gives_up_after_max_attempts():
    inner = FlakyEmbeddings([HttpError(429)] * 5)
    emb = BatchedEmbeddings(inner, max_attempts=3, sleep=lambda _: None)
    with pytest.raises(HttpError):
        emb.embed_documents(["x"])


def test_connection_errors_are_retryable():
    assert is_retryable(ConnectionError("reset"))
    assert not is_retryable(ValueError("bad input"))
