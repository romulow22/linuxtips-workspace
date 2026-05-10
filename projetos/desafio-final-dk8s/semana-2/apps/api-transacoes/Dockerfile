# syntax=docker/dockerfile:1.7
# =============================================================================
# STAGE 1 — builder
# =============================================================================
FROM cgr.dev/chainguard/python:latest-dev AS builder

WORKDIR /app

# Switch to root user to install OS packages and create target directory
USER root

# Install tini
RUN apk update && apk add --no-cache tini

# Create and set permissions for the /packages directory
RUN mkdir /packages && chown nonroot:nonroot /packages

# Switch back to non-root user for subsequent operations
USER nonroot

COPY requirements.txt .

# Set the PyO3 env var to allow building with Python 3.14
ENV PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1

# Install Python packages as non-root user
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --target=/packages -r requirements.txt

COPY main.py .

# =============================================================================
# STAGE 2 — runtime
# =============================================================================
FROM cgr.dev/chainguard/python:latest

WORKDIR /app

# Copy tini and Python packages from the builder stage
COPY --from=builder /sbin/tini /sbin/tini
COPY --from=builder /packages /packages
COPY --from=builder /app/main.py /app/main.py

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/packages \
    PATH=/packages/bin:$PATH \
    APP_VERSION=v1

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--", "python3", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
