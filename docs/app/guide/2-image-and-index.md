# App guide — Part 2: The image, the corpus and the index version (steps 10–13)

[← Part 1](1-pod-identity.md) · [Index](../guide.md) · [Concepts](0-concepts.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 1 is done, including step 7. This part does not need the cluster: it runs on
the workstation, against ECR and S3.

**Done when:**

- ECR holds one image, tagged with the 12-character commit, and its digest is recorded.
- The PDF sits at `corpus/` in the artifacts bucket, with a verified checksum.
- The index version that corpus builds is recorded, computed by that image.

**Every step follows [the loop](../guide.md#the-loop-for-every-step).**

---

The chart in Part 3 runs the index build as a Kubernetes Job and pins the index version in its values
file. The version is a hash of the corpus and the settings ([concepts §15](0-concepts.md#15-the-index-version)), and images are pinned by tag and digest
([concepts §14](0-concepts.md#14-image-tags-and-digests)). Three things are missing for that today:

1. **The Job has no way to get the PDF.** The image deliberately leaves `data/` out, and
   `python -m app.index build` reads only a local folder.
2. **Nothing ties the version in the values file to what the Job builds.** The Job would build whatever
   the corpus hashes to, and the pods would look for whatever the values say.
3. **`faiss/LATEST` moves on every build, even a skipped one.** With dev and prod both building, each
   sync would move the pointer the other one might read.

Step 10 fixes all three in the code, with tests. Steps 11–13 produce the three inputs Part 3 needs: an
image, a version, and the corpus in S3.

---

## Step 10 — The index CLI: corpus from S3, a `version` command, a pinned build

**Problem now.** The code has three gaps:

- **No PDF for the Job.** The build reads PDFs only from a local folder, and the image leaves `data/` out. A Kubernetes Job would find nothing to build.
- **Nothing ties the pinned version to the build** ([concepts §15](0-concepts.md#15-the-index-version)). A Job could build one version while the pods look for another, and that would only show when the pods fail to find their index.
- **`faiss/LATEST` moves on every build**, even one that skips. Dev and prod would keep moving a pointer they share.

**Why it matters.** The chart will pin one index version. The build must produce exactly that version, stop at once when it cannot (before spending Hugging Face quota on embedding calls), and never touch the shared pointer.

**This step.** We change the index code and add four tests. A new command, `python -m app.index version`, prints the version and nothing else. The build can read the PDF from S3 (`<CORPUS_STORE>/corpus/`). Before it calls the embedding API, it stops if the version is not the pinned one. In the cluster it never moves `faiss/LATEST`. On a laptop everything works as before.

**After this step.**
- Works: the code is in Git.
- Proven by: the test stage prints `All checks passed!` and `26 passed`.
- Still missing: no image contains this code → step 11.

| File | Change |
|---|---|
| `src/app/config/config.py` | Four new settings |
| `src/app/index.py` | Replaced (below) |
| `tests/test_index.py` | Four new tests |
| `.dockerignore` | `infra/` and `deploy/` out of the build context |

**Laptop.** In `src/app/config/config.py`, add after the line `EMBED_BATCH_SIZE = …`:
```python
# The Kubernetes Job reads the corpus from <CORPUS_STORE>/corpus/ instead of DATA_PATH.
CORPUS_STORE = os.getenv("CORPUS_STORE")
# The build fails unless the corpus hashes to this version: the one pinned in the values file.
INDEX_EXPECTED_VERSION = os.getenv("INDEX_EXPECTED_VERSION")
# Local runs move the faiss/LATEST pointer. The cluster pins every version, never moves LATEST, and
# refuses to read it.
INDEX_UPDATE_LATEST = os.getenv("INDEX_UPDATE_LATEST", "true").lower() == "true"
INDEX_REQUIRE_PINNED = os.getenv("INDEX_REQUIRE_PINNED", "false").lower() == "true"
```

Replace `src/app/index.py` with:
```python
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
```

Add to the end of `tests/test_index.py`:
```python


def test_build_refuses_an_unexpected_version_before_embedding(tmp_path):
    data = tmp_path / "data"
    data.mkdir()
    _write_pdf(data / "doc.pdf")
    embeddings = CountingEmbeddings()

    with pytest.raises(ValueError, match="was expected"):
        index.build(
            LocalStore(tmp_path / "store"),
            data,
            embeddings_factory=lambda: embeddings,
            expected_version="000000000000",
        )
    assert embeddings.calls == 0, "a wrong version must fail before any embedding call"


def test_build_can_leave_latest_alone(tmp_path, monkeypatch):
    data = tmp_path / "data"
    data.mkdir()
    _write_pdf(data / "doc.pdf")
    store = LocalStore(tmp_path / "store")

    from langchain_core.documents import Document

    monkeypatch.setattr(
        "app.components.pdf_loader.load_pdf_files",
        lambda _path: [Document(page_content="fever and headache " * 40, metadata={"page": 0})],
    )
    version = index.build(store, data, embeddings_factory=CountingEmbeddings, update_latest=False)

    assert store.exists(f"faiss/{version}/manifest.json")
    assert not store.exists(index.LATEST_KEY)


def test_pull_refuses_latest_when_a_pinned_version_is_required(tmp_path):
    with pytest.raises(ValueError, match="pinned"):
        index.pull(LocalStore(tmp_path / "store"), "latest", tmp_path / "pulled", require_pinned=True)


def test_version_command_reads_the_corpus_store(tmp_path, monkeypatch, capsys):
    corpus = tmp_path / "corpus-store" / "corpus"
    corpus.mkdir(parents=True)
    _write_pdf(corpus / "doc.pdf")
    monkeypatch.setattr(index.config, "CORPUS_STORE", f"file://{tmp_path / 'corpus-store'}")

    assert index.main(["version"]) == 0

    printed = capsys.readouterr().out.strip().splitlines()[-1]
    expected = index.compute_version(
        [corpus / "doc.pdf"],
        index.config.CHUNK_SIZE,
        index.config.CHUNK_OVERLAP,
        index.config.EMBEDDING_MODEL_NAME,
    )
    assert printed == expected
```

In `.dockerignore`, add two lines at the end:
```
infra/
deploy/
```

**Why:**

- **The version is checked before any embedding call.** A mismatch in the cluster means the values file
  and the corpus disagree. Failing in the first second costs nothing; failing after 150 s of Hugging Face
  calls wastes quota.
- **`LATEST` stays for docker compose.** Locally, `build` then `pull latest` is still the whole workflow.
  Every default keeps the local behaviour. Only the cluster turns `INDEX_UPDATE_LATEST` off and
  `INDEX_REQUIRE_PINNED` on.
- **File names are kept when the corpus is downloaded.** The version hashes the names as well as the
  bytes. A renamed PDF is a new version.
- **`version` prints on stdout, alone.** Step 12 reads its last line.

**Check before:** `git status --short` shows exactly ` M .dockerignore`, ` M src/app/config/config.py`,
` M src/app/index.py` and ` M tests/test_index.py`.

**Commit and push** (`git add .dockerignore src/app/config/config.py src/app/index.py tests/test_index.py`,
message `Index CLI: corpus from S3, version command, pinned builds`). Nothing deploys `src/` yet: Argo CD watches only `deploy/`, and no image is
built until step 11. So this push only makes the code reachable from the workstation.

**Check**, on the workstation after `git pull`. `--no-cache-filter test` makes the test stage run even
if an earlier run cached it, and `grep` keeps only the lines that matter:
```bash
docker buildx build --progress=plain --no-cache-filter test --target test . 2>&1 \
  | grep -E 'All checks passed|[0-9]+ (passed|failed)|ERROR'
```
Expected: `All checks passed!` from ruff, then a line with `26 passed`. Before this step the count was 22
([evidence](../../evidence/local.md)); the four new tests add four. Any failure: fix it on the laptop
and push again. Do not go on to step 11 with a red test stage.

---

## Step 11 — `make image`: build, test and push one immutable image

**Problem now.** The ECR repository (AWS's image registry, [concepts §14](0-concepts.md#14-image-tags-and-digests)) is empty, and nothing builds images for it: the old `Jenkinsfile` pushes to Docker Hub. Tags in the ECR repository are immutable. An image pushed from uncommitted code would keep its tag until someone deletes it, and that tag could never be reused for the right image.

**Why it matters.** The chart will pin a tag and a digest. The tag must name a commit anyone can check out, and the image must have passed its tests.

**This step.** `make image`. It refuses a working tree with uncommitted changes, a commit that is not pushed, or a tag that already exists. It runs the tests, builds, pushes, and prints the digest.

**After this step.**
- Works: one image, tagged with its commit.
- Proven by: a tag and digest line; ECR's vulnerability scan reports `COMPLETE`; a second `make image` refuses because the tag exists.
- Still missing: the index version has been measured only locally, not by this image → step 12.

| File | Change |
|---|---|
| `Makefile` | `image` target |

> **Irreversible.** ECR tags are immutable: a pushed tag can never be replaced, only deleted. So the
> target refuses to push unless three things hold. The working tree is clean. `HEAD` is exactly
> `origin/main`, so the tag names a commit anyone can check out. The tag is not in ECR yet.

**Laptop.** Add to the end of `Makefile`:
```make


# --- App image, built on the workstation until Jenkins takes over (app guide step 11) -----------
REGISTRY   = $(ACCOUNT_ID).dkr.ecr.$(REGION).amazonaws.com
IMAGE_REPO = $(REGISTRY)/$(PROJECT)
# The tag is the commit. ECR tags are immutable, so one commit is one image, never overwritten.
IMAGE_TAG  = $(shell git rev-parse --short=12 HEAD)

.PHONY: image

# Refuses to run on uncommitted or unpushed code, or when the tag already exists. Tests first.
image:
	@test -z "$$(git status --porcelain)" || { echo "Uncommitted changes: commit and push first"; exit 1; }
	@git fetch --quiet origin main
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || { echo "HEAD is not origin/main: git pull first"; exit 1; }
	@if out=$$(aws ecr describe-images --region $(REGION) --repository-name $(PROJECT) --image-ids imageTag=$(IMAGE_TAG) 2>&1); then \
	  echo "$(IMAGE_TAG) is already in ECR, and tags are immutable"; exit 1; \
	elif ! grep -q ImageNotFoundException <<<"$$out"; then \
	  echo "$$out"; exit 1; \
	fi
	docker buildx build --progress=plain --target test .
	aws ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin $(REGISTRY)
	docker buildx build --target runtime --provenance=false --sbom=false --tag $(IMAGE_REPO):$(IMAGE_TAG) --push .
	aws ecr describe-images --region $(REGION) --repository-name $(PROJECT) --image-ids imageTag=$(IMAGE_TAG) \
	  --query 'imageDetails[0].[imageTags[0],imageDigest]' --output text
```
Recipe lines start with a **tab**.

**Why:**

- **The ECR check reads the error, not just the exit code.** "Tag not found" and "no permission" both
  fail. Only `ImageNotFoundException` means the push may go ahead; anything else is printed and stops.
- **`--provenance=false --sbom=false`.** A single plain manifest, whose digest is the one the chart will
  pin. Buildx would otherwise push an index with attestation manifests. The SBOM is Jenkins' job later,
  with `cosign attest` (the Jenkins phase writes it with Trivy rather than Syft).
- **The test stage runs first.** An image that fails its own tests never reaches the registry. Here
  it usually prints `CACHED`: this step changes only the Makefile, which the test stage does not copy,
  so the result from step 10 still holds.
- **Built on the workstation for now.** The Dockerfile has no torch; the dependencies are faiss-cpu,
  numpy and LangChain. A t3.small with 2 GB of swap has room. Jenkins takes this job over later, with
  rootless BuildKit in the cluster.

**Check before:** `git status --short` shows only ` M Makefile`.

**Commit and push** (`git add Makefile`, message `Add make image`), then on the workstation, after
`git pull`:
```bash
make -n image
```
Expected: the printed commands include `docker buildx build --target runtime … --tag
<account>.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag:<12 hex> --push .`, followed by the
`aws ecr describe-images` line. Nothing runs yet.
```bash
make image
```

**Check:**

1. The last line is the tag and its digest: `<12 hex>	sha256:<64 hex>`. Record both.
2. The image was scanned on push:
   ```bash
   TAG=$(git rev-parse --short=12 HEAD)
   aws ecr describe-image-scan-findings \
     --repository-name medical-rag \
     --image-id imageTag="$TAG" \
     --query 'imageScanStatus.status' \
     --output text
   ```
   Expected: `COMPLETE`. If it says `IN_PROGRESS`, wait a minute and ask again. Record the severity
   counts:
   ```bash
   aws ecr describe-image-scan-findings \
     --repository-name medical-rag \
     --image-id imageTag="$TAG" \
     --query 'imageScanFindings.findingSeverityCounts'
   ```
3. The gate works: run `make image` again. Expected: `<tag> is already in ECR, and tags are immutable`,
   then make's `Error 1`, and nothing is built.

---

## Step 12 — The index version, computed by that image

**Problem now.** The version to pin ([concepts §15](0-concepts.md#15-the-index-version)) was computed earlier by a local build: `cc759ae1a093`. The chart must pin the value that *this image's* code computes. If the code or a default changed since, it would be different.

**Why it matters.** The build Job, running this image, checks the corpus against the pinned version and refuses a mismatch (step 10). A wrong pin stops every build.

**This step.** Run the `version` command inside the image, against `data/`. Nothing is committed.

**After this step.**
- Works: the value to pin is known.
- Proven by: `cc759ae1a093`.
- Still missing: the PDF exists only in Git, and the Job reads it from S3 → step 13.

Nothing is committed. On the workstation, with the tag **recorded in step 11**, not the current `HEAD`.
An evidence commit since then has moved `HEAD` to a commit that has no image:
```bash
ACC=$(aws sts get-caller-identity --query Account --output text)
TAG=<the 12-hex tag from step 11>
IMAGE=$ACC.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag:$TAG
docker run --rm \
  -v "$PWD/data:/data:ro" \
  -e DATA_PATH=/data \
  "$IMAGE" \
  python -m app.index version | tail -n 1
```
The image is still in the local Docker cache from step 11. If it is not, Docker pulls it with the ECR
login from `make image`, which lasts 12 hours. After that, log in again first:
`aws ecr get-login-password | docker login --username AWS --password-stdin $ACC.dkr.ecr.ap-southeast-1.amazonaws.com`.

Expected: `cc759ae1a093`. That is the version measured locally for the same PDF, with the default chunk
size, overlap and embedding model ([evidence](../../evidence/local.md)).

A different value means the PDF or a default changed since then. **Stop** and find out which before
going on: that value would be pinned in both environments.

**Record** the version, and the image it came from.

---

## Step 13 — The corpus in S3

**Problem now.** The build Job reads the corpus from `s3://<artifacts>/corpus/` (step 10), and there is nothing there.

**Why it matters.** The Job must hash exactly the bytes Git holds, under the same file name, because the name is part of the version ([concepts §15](0-concepts.md#15-the-index-version)). The bucket keeps its content across rebuilds, and an overwritten object can be recovered for only 30 days, so the upload must never replace anything.

**This step.** Upload the PDF once, with a condition that refuses to overwrite, and a SHA-256 checksum stored with the object.

**After this step.**
- Works: the corpus is in S3, where the Job reads it.
- Proven by: S3's checksum equals the file's.
- Still missing: nothing deploys the app yet: no DNS name, no chart → Part 3, written after step 7 passes.

> **Shared state.** The artifacts bucket keeps its content across rebuilds, and an overwritten object
> can be recovered for only 30 days (noncurrent versions expire). So the upload refuses to replace
> anything. First confirm there is nothing to replace:
> ```bash
> ACC=$(aws sts get-caller-identity --query Account --output text)
> ARTIFACTS=medical-rag-artifacts-$ACC
> PDF=The_GALE_ENCYCLOPEDIA_of_MEDICINE_SECOND.pdf
> aws s3api head-object --bucket "$ARTIFACTS" --key "corpus/$PDF"
> ```
> Expected: `An error occurred (404) when calling the HeadObject operation: Not Found`.
> - JSON with `ContentLength`: the corpus is already there. Skip the upload and go to the check below.
> - Any other error: **stop**.

Upload with a precondition: `--if-none-match '*'` makes S3 refuse the write if the key exists, even if it
appeared a second ago. The SHA-256 checksum is computed on the way and stored with the object:
```bash
aws s3api put-object \
  --bucket "$ARTIFACTS" \
  --key "corpus/$PDF" \
  --body "data/$PDF" \
  --if-none-match '*' \
  --checksum-algorithm SHA256
```
Expected: JSON with `ChecksumSHA256` and `VersionId`.

**Check:** S3's checksum equals the file's:
```bash
aws s3api head-object \
  --bucket "$ARTIFACTS" \
  --key "corpus/$PDF" \
  --checksum-mode ENABLED \
  --query ChecksumSHA256 \
  --output text
openssl dgst -sha256 -binary "data/$PDF" | base64
```
Expected: the same base64 string twice. Record it.

**Why this location.** The file name is part of the version hash, so the key keeps the exact name from
`data/`. The build Job downloads `corpus/` into a temporary folder (step 10), hashes it, and must arrive
at the version from step 12.

---

## After this part

Part 1 gave the app's pods their own roles, and this part produced the three inputs the chart pins:

| Input | Value | Where it goes |
|---|---|---|
| Image | `<account>.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag:<tag>@sha256:<digest>` | `image` in the values files |
| Index version | `cc759ae1a093` (or what step 12 printed) | `index.version` in the values files |
| Corpus | `s3://medical-rag-artifacts-<account>/corpus/` | the build Job's `CORPUS_STORE=s3://medical-rag-artifacts-<account>` (the code adds `corpus/`) |

Next: [Part 3](3-dev.md) puts the chart on the cluster, in dev.

---

[← Part 1](1-pod-identity.md) · [Index](../guide.md) · [Next: Part 3 →](3-dev.md) · [Troubleshooting](troubleshooting.md)
