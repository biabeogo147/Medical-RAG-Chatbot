import logging
import sys

from app.config.config import LOG_LEVEL

_configured = False


def _configure():
    global _configured
    if _configured:
        return
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s - %(message)s"))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(LOG_LEVEL)
    # One INFO line per HTTP call to HF/Gemini drowns out application logs.
    for noisy in ("httpx", "httpcore", "faiss.loader", "google_genai.models"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    _configured = True


def get_logger(name):
    _configure()
    return logging.getLogger(name)
