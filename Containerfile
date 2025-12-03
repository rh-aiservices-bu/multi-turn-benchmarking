# Multi-turn LLM Benchmark Tool
# Containerfile for OpenShift deployment

FROM registry.access.redhat.com/ubi9/python-311:latest

# Set labels for OpenShift
LABEL name="multi-turn-benchmark" \
      version="1.0" \
      description="Multi-turn conversation benchmark tool for LLM inference testing" \
      io.k8s.display-name="Multi-turn LLM Benchmark" \
      io.openshift.tags="python,benchmark,llm"

# Switch to root to install dependencies
USER 0

# Install httpx (the only external dependency)
RUN pip install --no-cache-dir httpx

# Create application directory
WORKDIR /opt/app-root/src

# Copy application code and seed documents, fix ownership for OpenShift
COPY --chown=1001:0 multi-turn-benchmark.py .
COPY --chown=1001:0 seed-documents/ ./seed-documents/

# Ensure proper permissions (readable by group 0 for OpenShift)
RUN chmod -R g=u /opt/app-root/src

# Switch back to default user for OpenShift compatibility
USER 1001

# Set the entrypoint
ENTRYPOINT ["python", "multi-turn-benchmark.py"]

# Default command shows help
CMD ["--help"]
