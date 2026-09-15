import os

from prometheus_client import multiprocess

bind = f"0.0.0.0:{os.getenv('APP_PORT', '8000')}"
worker_class = "gthread"
workers = int(os.getenv("GUNICORN_WORKERS", "2"))
threads = int(os.getenv("GUNICORN_THREADS", "4"))
timeout = 60
graceful_timeout = 30
accesslog = "-"
errorlog = "-"
# Keep worker heartbeat files off the read-only root filesystem.
worker_tmp_dir = os.getenv("GUNICORN_TMP_DIR", "/tmp")
# gunicorn >= 25.1 opens a management socket under $HOME; the orchestrator manages workers instead.
control_socket_disable = True


def child_exit(server, worker):
    if os.getenv("PROMETHEUS_MULTIPROC_DIR"):
        multiprocess.mark_process_dead(worker.pid)
