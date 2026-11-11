# syntax=docker/dockerfile:1
# =====================================================================
# Scanpy lab image, multi-arch (linux/amd64 + linux/arm64), Pixi-based.
#
# - The Pixi environment is installed at BUILD time (locked), so the
#   container starts instantly and reproducibly; no install-at-boot.
# - The Pixi CLI plus pixi.toml/pixi.lock are placed in /home/jovyan so
#   the documented `pixi run <CMD>` convention keeps working.
# - linux/amd64 is the canonical build for SciLifeLab Serve; Apple
#   Silicon machines pull the native linux/arm64 variant automatically.
# - libnosigtrap.so (Rosetta fork() workaround, see
#   patches/rosetta_fix/nosigtrap.c) is compiled for each target arch and
#   LD_PRELOADED: inert on native hosts, but it rescues students who force
#   `--platform=linux/amd64` on an M-chip Mac (apple/container#966).
# =====================================================================

# ---- Rosetta fix shim: cross-compiled at native speed per target ----
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS rosetta-fix
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc-x86-64-linux-gnu libc6-dev-amd64-cross \
      gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
 && rm -rf /var/lib/apt/lists/*
COPY patches/rosetta_fix/nosigtrap.c /src/nosigtrap.c
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      aarch64-linux-gnu-gcc -O2 -fPIC -shared -o /libnosigtrap.so /src/nosigtrap.c -ldl; \
    else \
      x86_64-linux-gnu-gcc -O2 -fPIC -shared -o /libnosigtrap.so /src/nosigtrap.c -ldl; \
    fi

# ---- Pixi environment, installed frozen for the target platform ----
FROM --platform=$TARGETPLATFORM ghcr.io/prefix-dev/pixi:0.84.1 AS scanpy-env
COPY envs/scanpy/pixi.toml envs/scanpy/pixi.lock /app/
WORKDIR /app
RUN pixi install --frozen

# ---- Runtime ----
FROM ubuntu:24.04 AS production
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git tini xz-utils \
 && rm -rf /var/lib/apt/lists/*

# User and paths match the SDC serve images: jovyan (uid 1000), home
# /home/jovyan, course data mounted at /home/jovyan/work, JupyterLab on
# 8888. Serve deployment and the docs stay unchanged.
RUN groupadd -g 100 users \
 && useradd -m -u 1000 -g 100 -s /bin/bash jovyan \
 && mkdir -p /home/jovyan/work

# Pixi CLI + manifest + prebuilt environment. With the env already
# installed and PIXI_LOCKED set, `pixi run` reuses it without re-solving.
COPY --from=scanpy-env /usr/local/bin/pixi /usr/local/bin/pixi
COPY envs/scanpy/pixi.toml envs/scanpy/pixi.lock /home/jovyan/
COPY --from=scanpy-env /app/.pixi /home/jovyan/.pixi
ENV PIXI_LOCKED=true

# Rosetta fork() fix for every process in the container
COPY --from=rosetta-fix /libnosigtrap.so /opt/rossetafix/libnosigtrap.so
ENV LD_PRELOAD=/opt/rossetafix/libnosigtrap.so

COPY scripts/download-labs.sh /home/jovyan/download-labs.sh
COPY scripts/scanpy-start-script.sh /home/jovyan/start-script.sh
RUN chmod a+x /home/jovyan/download-labs.sh /home/jovyan/start-script.sh \
 && chown -R jovyan:users /home/jovyan

USER jovyan
WORKDIR /home/jovyan

# Register the Jupyter kernel from the installed environment at build
# time (the old image created a pixi-wrapped kernel spec at start).
RUN /home/jovyan/.pixi/envs/default/bin/python -m ipykernel install \
      --user --name scanpy --display-name scanpy

EXPOSE 8888
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/home/jovyan/start-script.sh"]
