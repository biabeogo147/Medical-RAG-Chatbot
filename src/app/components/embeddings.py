import random
import time
from collections.abc import Callable

from langchain_core.embeddings import Embeddings
from langchain_huggingface import HuggingFaceEndpointEmbeddings

from app.common.logger import get_logger
from app.config.config import EMBED_BATCH_SIZE, EMBEDDING_MODEL_NAME, HUGGINGFACEHUB_API_TOKEN

logger = get_logger(__name__)

RETRYABLE_STATUS = {408, 429, 500, 502, 503, 504}


def _status_code(exc: Exception) -> int | None:
    response = getattr(exc, "response", None)
    return getattr(response, "status_code", None)


def is_retryable(exc: Exception) -> bool:
    status = _status_code(exc)
    if status is None:
        # No HTTP response at all: connection reset, timeout, DNS hiccup.
        return isinstance(exc, (ConnectionError, TimeoutError, OSError)) or "Timeout" in type(exc).__name__
    return status in RETRYABLE_STATUS


class BatchedEmbeddings(Embeddings):
    """Embeds documents in fixed-size batches with exponential backoff on transient API errors."""

    def __init__(
        self,
        inner: Embeddings,
        batch_size: int = EMBED_BATCH_SIZE,
        max_attempts: int = 6,
        base_delay_s: float = 1.0,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self.inner = inner
        self.batch_size = batch_size
        self.max_attempts = max_attempts
        self.base_delay_s = base_delay_s
        self.sleep = sleep

    def _with_retry(self, fn, *args):
        for attempt in range(1, self.max_attempts + 1):
            try:
                return fn(*args)
            except Exception as exc:
                if attempt == self.max_attempts or not is_retryable(exc):
                    raise
                delay = self.base_delay_s * 2 ** (attempt - 1) * (1 + random.random() * 0.25)
                logger.warning(
                    "Embedding call failed (attempt %d/%d, status=%s): %s; retrying in %.1fs",
                    attempt, self.max_attempts, _status_code(exc), exc, delay,
                )
                self.sleep(delay)

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        vectors: list[list[float]] = []
        total = len(texts)
        for start in range(0, total, self.batch_size):
            batch = texts[start:start + self.batch_size]
            vectors.extend(self._with_retry(self.inner.embed_documents, batch))
            logger.info("Embedded %d/%d chunks", min(start + self.batch_size, total), total)
        return vectors

    def embed_query(self, text: str) -> list[float]:
        return self._with_retry(self.inner.embed_query, text)


def get_embedding_model() -> Embeddings:
    if not HUGGINGFACEHUB_API_TOKEN:
        raise RuntimeError("HUGGINGFACEHUB_API_TOKEN is not set")
    inner = HuggingFaceEndpointEmbeddings(
        repo_id=EMBEDDING_MODEL_NAME,
        huggingfacehub_api_token=HUGGINGFACEHUB_API_TOKEN,
    )
    return BatchedEmbeddings(inner)
