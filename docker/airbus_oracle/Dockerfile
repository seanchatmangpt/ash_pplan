# Pinned Airbus Deliberation & Parity Oracle Container
# Platform: Linux x86_64 / arm64 (multi-arch compatible)
FROM python:3.11-slim-bookworm

LABEL org.opencontainers.image.title="Airbus Deliberation & Parity Oracle"
LABEL org.opencontainers.image.description="Automated planning, STNU controllability, and FOND deliberation daemon for ash_pplan parity courts"
LABEL org.opencontainers.image.version="26.11.0"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    ORACLE_SOCKET_PATH=/tmp/airbus_oracle.sock

# Install build dependencies for native planning engines (PRP, Fast-Downward, C++ solvers)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    flex \
    bison \
    socat \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/airbus_oracle

# Pin core deliberation libraries
# scikit-decide, unified-planning, tarski, pyshacl
RUN pip install --no-cache-dir \
    "scikit-decide>=0.14.0" \
    "unified-planning>=1.1.0" \
    "tarski>=0.8.2" \
    "pyshacl>=0.25.0"

COPY server.py /opt/airbus_oracle/server.py

# Create non-root user and ensure socket directory access
RUN useradd -m -u 1000 oracle && \
    chown -R oracle:oracle /opt/airbus_oracle && \
    mkdir -p /tmp && chmod 1777 /tmp

USER oracle

EXPOSE 4242

ENTRYPOINT ["python3", "/opt/airbus_oracle/server.py"]
