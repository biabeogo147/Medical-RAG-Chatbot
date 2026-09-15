import boto3
import pytest
from moto import mock_aws

from app.artifact_store import LocalStore, S3Store, store_from_url


def _roundtrip(store, tmp_path):
    src = tmp_path / "src"
    (src / "nested").mkdir(parents=True)
    (src / "index.faiss").write_bytes(b"\x00\x01")
    (src / "nested" / "manifest.json").write_text('{"v": 1}')

    assert not store.exists("faiss/abc/index.faiss")
    store.upload_dir(src, "faiss/abc")
    assert store.exists("faiss/abc/index.faiss")

    store.write_text("faiss/LATEST", "abc")
    assert store.read_text("faiss/LATEST") == "abc"

    dest = tmp_path / "dest"
    store.download_dir("faiss/abc", dest)
    assert (dest / "index.faiss").read_bytes() == b"\x00\x01"
    assert (dest / "nested" / "manifest.json").read_text() == '{"v": 1}'

    with pytest.raises(FileNotFoundError):
        store.download_dir("faiss/missing", tmp_path / "nope")


def test_local_store_roundtrip(tmp_path):
    _roundtrip(LocalStore(tmp_path / "store"), tmp_path)


@mock_aws
def test_s3_store_roundtrip(tmp_path):
    client = boto3.client("s3", region_name="us-east-1")
    client.create_bucket(Bucket="artifacts")
    _roundtrip(S3Store("artifacts", "/medical-rag/", client=client), tmp_path)


def test_store_from_url(tmp_path):
    assert isinstance(store_from_url("file:///index-store"), LocalStore)
    assert store_from_url("file:///index-store").root.as_posix() == "/index-store"
    with pytest.raises(ValueError):
        store_from_url("gs://bucket")
