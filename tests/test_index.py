import json
from pathlib import Path

import pytest
from langchain_core.embeddings import Embeddings
from pypdf import PdfWriter

from app import index
from app.artifact_store import LocalStore


class CountingEmbeddings(Embeddings):
    def __init__(self):
        self.calls = 0

    def embed_documents(self, texts):
        self.calls += 1
        return [[float(i % 7), 1.0, 0.5] for i, _ in enumerate(texts)]

    def embed_query(self, text):
        return [1.0, 1.0, 0.5]


def _write_pdf(path: Path, pages: int = 2) -> None:
    writer = PdfWriter()
    for _ in range(pages):
        writer.add_blank_page(width=200, height=200)
    with path.open("wb") as fh:
        writer.write(fh)


def test_version_is_deterministic_and_config_sensitive(tmp_path):
    pdf = tmp_path / "a.pdf"
    pdf.write_bytes(b"%PDF-1.4 same bytes")
    v1 = index.compute_version([pdf], 500, 50, "model-a")
    assert v1 == index.compute_version([pdf], 500, 50, "model-a")
    assert v1 != index.compute_version([pdf], 400, 50, "model-a")
    assert v1 != index.compute_version([pdf], 500, 50, "model-b")
    pdf.write_bytes(b"%PDF-1.4 different bytes")
    assert v1 != index.compute_version([pdf], 500, 50, "model-a")


def test_build_skips_existing_version_and_pull_restores(tmp_path, monkeypatch):
    data = tmp_path / "data"
    data.mkdir()
    _write_pdf(data / "doc.pdf")
    store = LocalStore(tmp_path / "store")

    from langchain_core.documents import Document

    monkeypatch.setattr(
        "app.components.pdf_loader.load_pdf_files",
        lambda _path: [Document(page_content="fever and headache " * 40, metadata={"page": 0})],
    )
    embeddings = CountingEmbeddings()

    version = index.build(store, data, embeddings_factory=lambda: embeddings)
    assert embeddings.calls == 1
    assert store.read_text(index.LATEST_KEY) == version

    assert index.build(store, data, embeddings_factory=lambda: embeddings) == version
    assert embeddings.calls == 1, "second build must not re-embed"

    manifest = index.pull(store, "latest", tmp_path / "pulled")
    assert manifest["version"] == version
    assert manifest["chunks"] > 1
    assert (tmp_path / "pulled" / "index.faiss").exists()
    assert json.loads((tmp_path / "pulled" / "manifest.json").read_text())["pages"] == 1


def test_build_fails_without_pdfs(tmp_path):
    (tmp_path / "data").mkdir()
    with pytest.raises(Exception, match="No PDF files"):
        index.build(LocalStore(tmp_path / "store"), tmp_path / "data", embeddings_factory=CountingEmbeddings)
