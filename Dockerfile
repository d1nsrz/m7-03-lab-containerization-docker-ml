# Modified Dockerfile — m7-03 lab (Containerization with Docker for ML) v2.
#
# Improvements over v1:
#   - Base image pinned by digest in BOTH stages (supply-chain hygiene)
#   - Provenance LABELs added to stage 2 (model source, framework, ORT version, maintainer)
#   - HEALTHCHECK added to stage 2
#
# How to get the current debian:12-slim digest before building:
#   docker pull debian:12-slim
#   docker inspect --format '{{index .RepoDigests 0}}' debian:12-slim
# Paste the printed digest (everything after the @) into DEBIAN_DIGEST below.
# Both stages must use the same digest.
#
# Build:    docker build -t <ns>/m7-03-cat-detection:v2 .
# Run:      docker run --rm <ns>/m7-03-cat-detection:v2
# Verify:   uid should be 1001; image size should be < ~250 MB

ARG ORT_VERSION=1.20.1

# 3b — pin the base image digest here. Replace the placeholder with the
#       real sha256 you get from the docker inspect command above.
#       Example: sha256:056653329ed9a985f2e1fcb76da48ad300561558ca9f4432e74db4d7fab1277c
ARG DEBIAN_DIGEST=sha256:056653329ed9a985f2e1fcb76da48ad300561558ca9f4432e74db4d7fab1277c

# ──────────────────────────────────────────────────────────────
# Stage 1 — builder
# ──────────────────────────────────────────────────────────────
# 3b: base image pinned by digest so this stage cannot silently drift
FROM --platform=linux/amd64 debian:12-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb AS builder
ARG ORT_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl file \
    && rm -rf /var/lib/apt/lists/*

# Fetch and extract the official ONNX Runtime release tarball
WORKDIR /opt
RUN curl -sSL -o ort.tgz \
        "https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/onnxruntime-linux-x64-${ORT_VERSION}.tgz" \
    && tar -xzf ort.tgz \
    && mv "onnxruntime-linux-x64-${ORT_VERSION}" onnxruntime \
    && rm ort.tgz

# Compile the model verifier against the extracted library
WORKDIR /build
COPY src/check_model.c .
RUN mkdir -p /out \
    && gcc -O2 -o /out/check_model check_model.c \
        -I/opt/onnxruntime/include \
        -L/opt/onnxruntime/lib \
        -lonnxruntime

# Validation gate — fail the build now if the model is missing/empty/bogus
COPY model.onnx /tmp/model.onnx
RUN test -s /tmp/model.onnx \
    && file /tmp/model.onnx | grep -qi onnx \
    && echo "Model SHA-256: $(sha256sum /tmp/model.onnx | awk '{print $1}')" \
    && echo "Model size:    $(stat -c%s /tmp/model.onnx) bytes"

# ──────────────────────────────────────────────────────────────
# Stage 2 — runtime
# ──────────────────────────────────────────────────────────────
# 3b: same digest as stage 1 — both stages pin to the identical base layer
FROM --platform=linux/amd64 debian:12-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb AS runtime
ARG ORT_VERSION

# Runtime-only deps: ca-certs for general hygiene; libstdc++6 because the
# ONNX Runtime shared library uses C++ symbols internally
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN useradd --create-home --uid 1001 app

# Copy the shared library (with symlinks preserved), the binary, and the model
COPY --from=builder /opt/onnxruntime/lib/libonnxruntime.so* /usr/local/lib/
COPY --from=builder /out/check_model /usr/local/bin/check_model
COPY --from=builder --chown=app:app /tmp/model.onnx /home/app/model.onnx

# Tell the dynamic linker where to find libonnxruntime at runtime
ENV LD_LIBRARY_PATH=/usr/local/lib

# 3a — provenance LABELs: records what model and runtime version are baked in,
#      and who is responsible. Visible via docker image inspect.
LABEL model.source="m6-09-assessment"
LABEL model.framework="ultralytics-yolo26"
LABEL ort.version="${ORT_VERSION}"
LABEL maintainer="<your-github-handle>"

USER app
WORKDIR /home/app

# 3c — HEALTHCHECK: orchestrators (Compose, Swarm, K8s liveness probes via
#      exec) will run this command every 30 s. For a verifier container the
#      health check is the same as CMD — in a real serving container it would
#      hit a /health HTTP endpoint instead.
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD check_model /home/app/model.onnx || exit 1

CMD ["check_model", "/home/app/model.onnx"]
