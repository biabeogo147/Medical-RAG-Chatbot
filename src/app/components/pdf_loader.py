from pathlib import Path

from langchain_community.document_loaders import DirectoryLoader, PyPDFLoader
from langchain_core.documents import Document
from langchain_text_splitters import RecursiveCharacterTextSplitter

from app.common.custom_exception import CustomException
from app.common.logger import get_logger
from app.config.config import CHUNK_OVERLAP, CHUNK_SIZE, DATA_PATH

logger = get_logger(__name__)


def pdf_files(data_path: Path = DATA_PATH) -> list[Path]:
    if not data_path.is_dir():
        raise CustomException(f"Data path does not exist: {data_path}")
    files = sorted(data_path.glob("*.pdf"))
    if not files:
        raise CustomException(f"No PDF files found in {data_path}")
    return files


def load_pdf_files(data_path: Path = DATA_PATH) -> list[Document]:
    pdf_files(data_path)
    logger.info("Loading PDFs from %s", data_path)
    documents = DirectoryLoader(str(data_path), glob="*.pdf", loader_cls=PyPDFLoader).load()
    logger.info("Loaded %d pages", len(documents))
    return documents


def create_text_chunks(
    documents: list[Document], chunk_size: int = CHUNK_SIZE, chunk_overlap: int = CHUNK_OVERLAP
) -> list[Document]:
    if not documents:
        raise CustomException("No documents to split")
    splitter = RecursiveCharacterTextSplitter(chunk_size=chunk_size, chunk_overlap=chunk_overlap)
    chunks = splitter.split_documents(documents)
    logger.info("Split %d pages into %d chunks", len(documents), len(chunks))
    return chunks
