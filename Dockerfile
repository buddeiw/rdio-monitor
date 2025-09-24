# Dockerfile for Rdio Scanner Monitor Application
# This builds a container image for the Python scanner application
# Following best practices for security, performance, and maintainability

# Use official Python slim image as base for smaller size and security
FROM python:3.11-slim-bookworm

# Metadata labels following OCI specification
LABEL org.opencontainers.image.title="Rdio Scanner Monitor"
LABEL org.opencontainers.image.description="Monitors Rdio Scanner domains and logs call data with audio capture"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.created="2024-01-01T00:00:00Z"
LABEL org.opencontainers.image.authors="System Administrator"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.documentation="https://github.com/your-org/rdio-scanner-monitor"

# Set environment variables for Python optimization and container behavior
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONIOENCODING=utf-8 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_DEFAULT_TIMEOUT=100 \
    DEBIAN_FRONTEND=noninteractive

# Create non-root user for security (following principle of least privilege)
RUN groupadd --gid 1000 appuser && \
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash appuser

# Install system dependencies required for audio processing and Python packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        # Audio processing dependencies
        ffmpeg \
        libavcodec-dev \
        libavformat-dev \
        libavutil-dev \
        # Network and SSL dependencies
        ca-certificates \
        curl \
        # PostgreSQL client libraries
        libpq-dev \
        # Build dependencies for Python packages
        gcc \
        g++ \
        # Process management utilities
        supervisor \
        # System monitoring tools
        htop \
        procps \
        # Cleanup utilities
        && apt-get clean \
        && rm -rf /var/lib/apt/lists/* \
        && rm -rf /tmp/* \
        && rm -rf /var/tmp/*

# Set up application directory structure
WORKDIR /app

# Create necessary directories with proper permissions
RUN mkdir -p \
    /app/audio \
    /app/logs \
    /app/temp \
    /app/config \
    /app/scripts \
    && chown -R appuser:appuser /app

# Copy Python requirements file first (for Docker layer caching optimization)
COPY requirements.txt /app/requirements.txt

# Install Python dependencies with security and performance optimizations
RUN pip install --no-cache-dir --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -r requirements.txt && \
    # Remove build dependencies to reduce image size
    apt-get update && \
    apt-get remove -y gcc g++ && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy application code with proper ownership
COPY --chown=appuser:appuser rdio_scanner.py /app/rdio_scanner.py
COPY --chown=appuser:appuser health_check.py /app/health_check.py
COPY --chown=appuser:appuser entrypoint.sh /app/entrypoint.sh

# Copy supervisor configuration for process management
COPY --chown=appuser:appuser supervisord.conf /app/supervisord.conf

# Make scripts executable
RUN chmod +x /app/entrypoint.sh /app/health_check.py

# Create configuration template
COPY --chown=appuser:appuser config.ini.template /app/config/config.ini.template

# Set up proper permissions for application directories
RUN chown -R appuser:appuser /app && \
    chmod -R 755 /app && \
    chmod -R 777 /app/audio /app/logs /app/temp

# Switch to non-root user for security
USER appuser

# Expose ports for health checks and monitoring
EXPOSE 8080

# Define volumes for persistent data
VOLUME ["/app/audio", "/app/logs", "/app/config"]

# Health check configuration
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python3 /app/health_check.py || exit 1

# Set the entrypoint and default command
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["python3", "/app/rdio_scanner.py", "/app/config/config.ini"]