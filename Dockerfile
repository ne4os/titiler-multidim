ARG PYTHON_VERSION=3.12

# ---------- Builder stage ----------
# Ubuntu-small-latest ships Ubuntu 24.04 + Python 3.12, matching this
# project's `requires-python = ">=3.12"`. Pin to a specific GDAL version
# tag (see https://github.com/OSGeo/gdal/pkgs/container/gdal) if you need
# reproducible builds.
FROM ghcr.io/osgeo/gdal:ubuntu-small-latest AS builder

ARG PYTHON_VERSION
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip \
        build-essential \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install uv (fast resolver/installer used by the project)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

WORKDIR /app

# Copy only dependency-defining files first for better layer caching
COPY pyproject.toml uv.lock* README.md ./
COPY src ./src

# Install the project + its "server" extra (adds uvicorn) into a venv,
# without the heavier dev/deployment/notebooks dependency groups.
RUN uv venv /opt/venv \
    && VIRTUAL_ENV=/opt/venv uv pip install ".[server]"

# ---------- Runtime stage ----------
FROM ghcr.io/osgeo/gdal:ubuntu-small-latest AS runtime

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
    HOST=0.0.0.0 \
    PORT=8000

USER titiler
WORKDIR /home/titiler

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS "http://localhost:${PORT}/healthz" || exit 1

CMD ["sh", "-c", "uvicorn titiler.multidim.main:app --host ${HOST} --port ${PORT}"]
