from pathlib import Path

from langchain_community.vectorstores import FAISS
from langchain_core.documents import Document
from langchain_core.embeddings import Embeddings

from app.common.custom_exception import CustomException
from app.common.logger import get_logger

logger = get_logger(__name__)


def build_vector_store(chunks: list[Document], embedding_model: Embeddings) -> FAISS:
    if not chunks:
        raise CustomException("No chunks to index")
    logger.info("Embedding %d chunks", len(chunks))
    return FAISS.from_documents(chunks, embedding_model)


def save_vector_store(db: FAISS, index_dir: Path) -> None:
    index_dir.mkdir(parents=True, exist_ok=True)
    db.save_local(str(index_dir))
    logger.info("Saved FAISS index to %s", index_dir)


def load_vector_store(index_dir: Path, embedding_model: Embeddings) -> FAISS:
    if not (index_dir / "index.faiss").exists():
        raise CustomException(f"No FAISS index found in {index_dir}")
    # The pickle is produced by our own index build job, never by users.
    return FAISS.load_local(str(index_dir), embedding_model, allow_dangerous_deserialization=True)
