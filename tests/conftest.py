import os

os.environ.setdefault("FLASK_SECRET_KEY", "test-secret")
os.environ.pop("PROMETHEUS_MULTIPROC_DIR", None)
