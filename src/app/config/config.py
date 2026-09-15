import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BASE_DIR.parents[2]

# Corpus and chunking
DATA_PATH = Path(os.getenv("DATA_PATH", PROJECT_ROOT / "data"))
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", 500))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", 50))

# Index artifact: built once, stored in INDEX_STORE, pulled into INDEX_DIR at startup
INDEX_DIR = Path(os.getenv("INDEX_DIR", "/tmp/index"))
INDEX_STORE = os.getenv("INDEX_STORE", f"file://{PROJECT_ROOT / 'index-store'}")
INDEX_VERSION = os.getenv("INDEX_VERSION", "latest")
EMBED_BATCH_SIZE = int(os.getenv("EMBED_BATCH_SIZE", 64))

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
