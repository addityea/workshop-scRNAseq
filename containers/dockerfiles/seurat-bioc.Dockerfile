# syntax=docker/dockerfile:1
# Rosetta fork() fix (macOS 26+): cross-compile the SIGTRAP interposer at
# native build speed, then bake it into the amd64 course image. Without it,
# RStudio/Python kernels in linux/amd64 containers hang on startup at
# "Starting kernel..." on Apple Silicon (apple/container#966). The shim is
# inert on real x86_64 hosts.
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS rosetta-fix
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc-x86-64-linux-gnu libc6-dev-amd64-cross \
 && rm -rf /var/lib/apt/lists/*
COPY patches/rosetta_fix/nosigtrap.c /src/nosigtrap.c
RUN x86_64-linux-gnu-gcc -O2 -fPIC -shared -o /libnosigtrap.so /src/nosigtrap.c -ldl

FROM ghcr.io/scilifelabdatacentre/serve-rstudio:250304-1611

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

COPY --from=rosetta-fix /libnosigtrap.so /opt/rossetafix/libnosigtrap.so
ENV LD_PRELOAD=/opt/rossetafix/libnosigtrap.so

COPY scripts/install_seurat_bioc.sh /tmp/scripts/

RUN /tmp/scripts/install_seurat_bioc.sh

COPY conda/seurat-bioc-environment-2025.yaml conda/seurat-bioc-conda-lock.yaml /tmp/conda/

RUN /usr/local/conda/bin/conda-lock install \
    --conda /usr/local/conda/bin/conda \
    --prefix /usr/local/conda/envs/seurat \
    /tmp/conda/seurat-bioc-conda-lock.yaml \
    && /usr/local/conda/bin/conda clean --all -f -y

# Configure container start
COPY scripts/seurat-start-script.sh ${HOME}/start-script.sh
COPY scripts/download-labs.sh ${HOME}/download-labs.sh

RUN chown -R jovyan:users ${HOME} \
    && chmod a+x ${HOME}/start-script.sh \
    && chmod a+x ${HOME}/download-labs.sh

USER jovyan

RUN mkdir -p ${HOME}/work \
    && chown -R jovyan:users ${HOME}/work \
    && cp ~/.bashrc ~/.bash_profile

WORKDIR ${HOME}

EXPOSE 8787

ENTRYPOINT ["/tini", "-g", "--", "./start-script.sh"]
