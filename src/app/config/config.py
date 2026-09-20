import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BASE_DIR.parents[2]

# Corpus and chunking
DATA_PATH = Path(os.getenv("DATA_PATH", PROJECT_ROOT / "data"))
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", 501))  # TEMPORARY: Jenkins guide step 15, case 2. Revert.
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", 50))

# Index artifact: built once, stored in INDEX_STORE, pulled into INDEX_DIR at startup
INDEX_DIR = Path(os.getenv("INDEX_DIR", "/tmp/index"))
INDEX_STORE = os.getenv("INDEX_STORE", f"file://{PROJECT_ROOT / 'index-store'}")
INDEX_VERSION = os.getenv("INDEX_VERSION", "latest")
EMBED_BATCH_SIZE = int(os.getenv("EMBED_BATCH_SIZE", 64))

# The Kubernetes Job reads the corpus from <CORPUS_STORE>/corpus/ instead of DATA_PATH.
CORPUS_STORE = os.getenv("CORPUS_STORE")
# The build fails unless the corpus hashes to this version: the one pinned in the values file.
INDEX_EXPECTED_VERSION = os.getenv("INDEX_EXPECTED_VERSION")
# Local runs move the faiss/LATEST pointer. The cluster pins every version, never moves LATEST, and
# refuses to read it.
INDEX_UPDATE_LATEST = os.getenv("INDEX_UPDATE_LATEST", "true").lower() == "true"
INDEX_REQUIRE_PINNED = os.getenv("INDEX_REQUIRE_PINNED", "false").lower() == "true"

# Models
MODEL_NAME = os.getenv("MODEL_NAME", "gemini-3.5-flash-lite")
EMBEDDING_MODEL_NAME = os.getenv("EMBEDDING_MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")
RETRIEVER_K = int(os.getenv("RETRIEVER_K", 3))
LLM_TIMEOUT_S = float(os.getenv("LLM_TIMEOUT_S", 30))

GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY")
HUGGINGFACEHUB_API_TOKEN = os.getenv("HUGGINGFACEHUB_API_TOKEN")

# Web
FLASK_SECRET_KEY = os.getenv("FLASK_SECRET_KEY")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
