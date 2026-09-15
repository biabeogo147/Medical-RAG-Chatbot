"""Build the FAISS index once as a versioned artifact, and pull it at startup.

    python -m app.index build   # embed the corpus unless this exact version already exists
    python -m app.index pull    # download INDEX_VERSION (or the LATEST pointer) into INDEX_DIR
"""

import argparse
import hashlib
import json
import sys
import tempfile
import time
from pathlib import Path

from app.artifact_store import store_from_url
from app.common.logger import get_logger
from app.config import config

logger = get_logger(__name__)

LATEST_KEY = "faiss/LATEST"


def compute_version(pdfs: list[Path], chunk_size: int, chunk_overlap: int, embedding_model: str) -> str:
    digest = hashlib.sha256()
    for pdf in sorted(pdfs, key=lambda p: p.name):
        digest.update(pdf.name.encode())
        with pdf.open("rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                digest.update(block)
    digest.update(f"{chunk_size}:{chunk_overlap}:{embedding_model}".encode())
    return digest.hexdigest()[:12]


def build(store, data_path: Path, embeddings_factory=None) -> str:
    from app.components.pdf_loader import create_text_chunks, load_pdf_files, pdf_files
    from app.components.vector_store import build_vector_store, save_vector_store

    version = compute_version(
        pdf_files(data_path), config.CHUNK_SIZE, config.CHUNK_OVERLAP, config.EMBEDDING_MODEL_NAME
    )
    prefix = f"faiss/{version}"
    if store.exists(f"{prefix}/manifest.json"):
        logger.info("Index version %s already exists, skipping build", version)
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
    store.write_text(LATEST_KEY, version)
    logger.info("Built index %s: %d pages, %d chunks in %ss", version, len(pages), len(chunks), duration)
    return version


def pull(store, version: str, index_dir: Path) -> dict:
    if version == "latest":
        version = store.read_text(LATEST_KEY).strip()
    store.download_dir(f"faiss/{version}", index_dir)
    manifest = json.loads((index_dir / "manifest.json").read_text(encoding="utf-8"))
    logger.info("Pulled index %s (%d chunks) into %s", version, manifest["chunks"], index_dir)
    return manifest


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.index")
    parser.add_argument("command", choices=["build", "pull"])
    args = parser.parse_args(argv)
    store = store_from_url(config.INDEX_STORE)
    try:
        if args.command == "build":
            build(store, config.DATA_PATH)
        else:
            pull(store, config.INDEX_VERSION, config.INDEX_DIR)
    except Exception:
        logger.exception("Index %s failed", args.command)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
