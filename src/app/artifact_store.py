"""Where index artifacts live: a local directory (docker compose) or S3 (Kubernetes)."""

import shutil
from pathlib import Path
from urllib.parse import urlparse


class LocalStore:
    def __init__(self, root: Path):
        self.root = root

    def exists(self, key: str) -> bool:
        return (self.root / key).exists()

    def upload_dir(self, local_dir: Path, prefix: str) -> None:
        target = self.root / prefix
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(local_dir, target)

    def download_dir(self, prefix: str, local_dir: Path) -> None:
        source = self.root / prefix
        if not source.is_dir():
            raise FileNotFoundError(f"{source} not found")
        shutil.copytree(source, local_dir, dirs_exist_ok=True)

    def read_text(self, key: str) -> str:
        return (self.root / key).read_text(encoding="utf-8")

    def write_text(self, key: str, text: str) -> None:
        path = self.root / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


class S3Store:
    def __init__(self, bucket: str, base_prefix: str = "", client=None):
        import boto3

        self.bucket = bucket
        self.base_prefix = base_prefix.strip("/")
        self.s3 = client or boto3.client("s3")

    def _key(self, key: str) -> str:
        return f"{self.base_prefix}/{key}" if self.base_prefix else key

    def exists(self, key: str) -> bool:
        resp = self.s3.list_objects_v2(Bucket=self.bucket, Prefix=self._key(key), MaxKeys=1)
        return resp.get("KeyCount", 0) > 0

    def upload_dir(self, local_dir: Path, prefix: str) -> None:
        for path in sorted(local_dir.rglob("*")):
            if path.is_file():
                rel = path.relative_to(local_dir).as_posix()
                self.s3.upload_file(str(path), self.bucket, self._key(f"{prefix}/{rel}"))

    def download_dir(self, prefix: str, local_dir: Path) -> None:
        full_prefix = self._key(prefix).rstrip("/") + "/"
        paginator = self.s3.get_paginator("list_objects_v2")
        found = False
        for page in paginator.paginate(Bucket=self.bucket, Prefix=full_prefix):
            for obj in page.get("Contents", []):
                found = True
                dest = local_dir / obj["Key"][len(full_prefix):]
                dest.parent.mkdir(parents=True, exist_ok=True)
                self.s3.download_file(self.bucket, obj["Key"], str(dest))
        if not found:
            raise FileNotFoundError(f"s3://{self.bucket}/{full_prefix} not found")

    def read_text(self, key: str) -> str:
        return self.s3.get_object(Bucket=self.bucket, Key=self._key(key))["Body"].read().decode("utf-8")

    def write_text(self, key: str, text: str) -> None:
        self.s3.put_object(Bucket=self.bucket, Key=self._key(key), Body=text.encode("utf-8"))


def store_from_url(url: str):
    parsed = urlparse(url)
    if parsed.scheme == "file":
        # file:///index-store  ->  /index-store ; file://D:/x -> D:/x
        return LocalStore(Path(parsed.netloc + parsed.path))
    if parsed.scheme == "s3":
        return S3Store(parsed.netloc, parsed.path)
    raise ValueError(f"Unsupported INDEX_STORE scheme: {url}")
