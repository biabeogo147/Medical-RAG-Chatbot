#!/bin/sh
set -eu

# prometheus_client multiprocess mode needs a clean shared directory per container start.
rm -rf "${PROMETHEUS_MULTIPROC_DIR:?}" && mkdir -p "$PROMETHEUS_MULTIPROC_DIR"

# In Kubernetes an initContainer pulls the index; locally the app pulls it itself.
if [ "${INDEX_PULL_ON_START:-true}" = "true" ]; then
    python -m app.index pull
fi

exec gunicorn -c gunicorn.conf.py 'app.application:create_app()'
