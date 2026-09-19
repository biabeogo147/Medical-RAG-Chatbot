"""Build the FAISS index once as a versioned artifact, and pull it at startup.

    python -m app.index version  # print the version the corpus builds, and nothing else
    python -m app.index build    # embed the corpus unless this exact version already exists
    python -m app.index pull     # download INDEX_VERSION (or the LATEST pointer) into INDEX_DIR

The corpus is DATA_PATH, or the corpus/ prefix of CORPUS_STORE when that is set (the Kubernetes Job).
"""

import argparse
import hashlib
import json
import sys
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from app.artifact_store import store_from_url
from app.common.logger import get_logger
from app.config import config

logger = get_logger(__name__)

LATEST_KEY = "faiss/LATEST"
CORPUS_PREFIX = "corpus"


def compute_version(pdfs: list[Path], chunk_size: int, chunk_overlap: int, embedding_model: str) -> str:
    digest = hashlib.sha256()
    for pdf in sorted(pdfs, key=lambda p: p.name):
        digest.update(pdf.name.encode())
        with pdf.open("rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                digest.update(block)
    digest.update(f"{chunk_size}:{chunk_overlap}:{embedding_model}".encode())
    return digest.hexdigest()[:12]


def corpus_version(data_path: Path) -> str:
    from app.components.pdf_loader import pdf_files

    return compute_version(
        pdf_files(data_path), config.CHUNK_SIZE, config.CHUNK_OVERLAP, config.EMBEDDING_MODEL_NAME
    )


@contextmanager
def corpus_dir() -> Iterator[Path]:
    """DATA_PATH, or a temporary copy of <CORPUS_STORE>/corpus/. File names are kept: they are hashed."""
    if not config.CORPUS_STORE:
        yield config.DATA_PATH
        return
    with tempfile.TemporaryDirectory() as tmp:
        local = Path(tmp)
        store_from_url(config.CORPUS_STORE).download_dir(CORPUS_PREFIX, local)
        yield local


def build(store, data_path: Path, embeddings_factory=None, expected_version=None, update_latest=True) -> str:
    from app.components.pdf_loader import create_text_chunks, load_pdf_files
    from app.components.vector_store import build_vector_store, save_vector_store

    version = corpus_version(data_path)
    if expected_version and version != expected_version:
        raise ValueError(
            f"The corpus builds version {version}, but {expected_version} was expected: "
            "update index.version in the values file, or check the corpus"
        )
    prefix = f"faiss/{version}"
    if store.exists(f"{prefix}/manifest.json"):
        logger.info("Index version %s already exists, skipping build", version)
        if update_latest:
            store.write_text(LATEST_KEY, version)
        return version

    if embeddings_factory is None:
        from app.components.embeddings import get_embedding_model as embeddings_factory

    started = time.monotonic()
    pages = load_pdf_files(data_path)
    chunks = create_text_chunks(pages)
    db = build_vector_store(chunks, embeddings_factory())
    duration = round(time.monotonic() - started, 1)

    manifest = {
        "version": version,
        "pages": len(pages),
        "chunks": len(chunks),
        "chunk_size": config.CHUNK_SIZE,
        "chunk_overlap": config.CHUNK_OVERLAP,
        "embedding_model": config.EMBEDDING_MODEL_NAME,
        "build_duration_s": duration,
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp)
        save_vector_store(db, out)
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        store.upload_dir(out, prefix)
    if update_latest:
        store.write_text(LATEST_KEY, version)
    logger.info("Built index %s: %d pages, %d chunks in %ss", version, len(pages), len(chunks), duration)
    return version


def pull(store, version: str, index_dir: Path, require_pinned: bool = False) -> dict:
    if version == "latest":
        if require_pinned:
            raise ValueError("INDEX_VERSION is 'latest', but a pinned version is required here")
        version = store.read_text(LATEST_KEY).strip()
    store.download_dir(f"faiss/{version}", index_dir)
    manifest = json.loads((index_dir / "manifest.json").read_text(encoding="utf-8"))
    logger.info("Pulled index %s (%d chunks) into %s", version, manifest["chunks"], index_dir)
    return manifest


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.index")
    parser.add_argument("command", choices=["version", "build", "pull"])
    args = parser.parse_args(argv)
    try:
        if args.command == "pull":
            pull(
                store_from_url(config.INDEX_STORE),
                config.INDEX_VERSION,
                config.INDEX_DIR,
                require_pinned=config.INDEX_REQUIRE_PINNED,
            )
            return 0
        with corpus_dir() as data_path:
            if args.command == "version":
                print(corpus_version(data_path))
            else:
                build(
                    store_from_url(config.INDEX_STORE),
                    data_path,
                    expected_version=config.INDEX_EXPECTED_VERSION,
                    update_latest=config.INDEX_UPDATE_LATEST,
                )
    except Exception:
        logger.exception("Index %s failed", args.command)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
