ARG PYTHON_VERSION=3.12
ARG GDAL_TAG=ubuntu-small-3.11.4

# ---------- Builder stage ----------
FROM ghcr.io/osgeo/gdal:${GDAL_TAG} AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip \
        build-essential \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/
WORKDIR /app

COPY pyproject.toml uv.lock* README.md ./
COPY src ./src

RUN uv venv /opt/venv \
    && VIRTUAL_ENV=/opt/venv uv pip install ".[server]" \
        "titiler-core==2.2.1" "titiler-xarray==2.2.1" \
        gunicorn uvicorn-worker

# titiler.xarray >= 0.25 only opens Zarr. This patch, loaded at interpreter start via a .pth
# file, routes .nc/.nc4 to the fsspec + h5netcdf reader and keeps the obstore reader for Zarr.
COPY <<'EOF' /tmp/titiler_nc_patch.py
import attr
import titiler.xarray.io as io

_open_zarr = io.open_zarr


def open_any(src_path, **kwargs):
    if src_path.lower().split("?")[0].endswith((".nc", ".nc4")):
        kwargs.pop("infer_region", None)
        return io.fs_open_dataset(src_path, **kwargs)
    return _open_zarr(src_path, **kwargs)


@attr.s
class AnyReader(io.Reader):
    opener = attr.ib(default=open_any)


# Must run before titiler.xarray.factory/extensions/main are imported (they bind these at import time).
io.open_zarr = open_any
io.Reader = AnyReader
EOF

RUN SP=$(/opt/venv/bin/python -c "import site; print(site.getsitepackages()[0])") \
    && cp /tmp/titiler_nc_patch.py "$SP/" \
    && echo "import titiler_nc_patch" > "$SP/titiler_nc_patch.pth"

# ---------- Runtime stage ----------
FROM ghcr.io/osgeo/gdal:${GDAL_TAG} AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home titiler

COPY --from=builder /opt/venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONFAULTHANDLER=1 \
    HOST=0.0.0.0 \
    PORT=8000 \
    WEB_CONCURRENCY=2 \
    MAX_REQUESTS=512 \
    MAX_REQUESTS_JITTER=100 \
    WORKER_TIMEOUT=120 \
    FORWARDED_ALLOW_IPS='*' \
    TITILER_XARRAY_API_ROOT_PATH=/titiler-multidim \
    MALLOC_ARENA_MAX=2 \
    MALLOC_TRIM_THRESHOLD_=0 \
    GDAL_CACHEMAX=200 \
    VSI_CACHE=TRUE \
    VSI_CACHE_SIZE=5000000 \
    GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR \
    GDAL_HTTP_MERGE_CONSECUTIVE_RANGES=YES \
    GDAL_HTTP_MULTIPLEX=YES \
    GDAL_HTTP_VERSION=2

USER titiler
WORKDIR /home/titiler

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS "http://localhost:${PORT}/healthz" || exit 1

CMD ["sh", "-c", "exec gunicorn titiler.xarray.main:app \
  --worker-class uvicorn_worker.UvicornWorker \
  --workers ${WEB_CONCURRENCY} \
  --bind ${HOST}:${PORT} \
  --max-requests ${MAX_REQUESTS} \
  --max-requests-jitter ${MAX_REQUESTS_JITTER} \
  --timeout ${WORKER_TIMEOUT} \
  --graceful-timeout 30"]