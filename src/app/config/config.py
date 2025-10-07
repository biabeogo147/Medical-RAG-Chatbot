import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

DB_FAISS_PATH = os.path.join(BASE_DIR, "vectorstore")
DATA_PATH = (BASE_DIR / "../../../data/").resolve()
CHUNK_OVERLAP = 50
CHUNK_SIZE = 500

MODEL_NAME = os.getenv("MODEL_NAME", "gemma-3n-e2b-it")
EMBEDDING_MODEL_NAME = os.getenv("EMBEDDING_MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")

GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY")
HUGGINGFACEHUB_API_TOKEN = os.getenv("HUGGINGFACEHUB_API_TOKEN")

APP_PORT = int(os.getenv("APP_PORT", 8000))