# syntax=docker/dockerfile:1
# Rosetta fork() fix (macOS 26+): compile the SIGTRAP interposer, then bake
# it into the amd64 course image. Without it, RStudio/Python kernels in
# linux/amd64 containers hang at "Starting kernel..." on Apple Silicon
# (apple/container#966). The shim is inert on real x86_64 hosts.
# Built from ubuntu:20.04 so the glibc baseline (2.31) matches the oldest
# serve base (serve-rstudio, Ubuntu 20.04) and runs on newer bases too.
FROM ubuntu:20.04 AS rosetta-fix
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/*
COPY patches/rosetta_fix/nosigtrap.c /src/nosigtrap.c
RUN gcc -O2 -fPIC -shared -o /libnosigtrap.so /src/nosigtrap.c -ldl

# ---- Seurat/Bioconductor environment from Pixi, locked at build time ----
# Conda-style envs hardcode absolute paths and are NOT relocatable, so the
# builder path below is baked into the binaries. It is exposed at
# /usr/local/conda/envs/seurat via a symlink: that is the path the
# Bioconductor/Seurat integration labs hardcode as basilisk `condapath`.
# The start script puts this env on PATH; conda is not installed at all.
FROM ghcr.io/prefix-dev/pixi:0.84.1 AS seurat-env
COPY envs/seurat/pixi.toml envs/seurat/pixi.lock /opt/seurat-pixi/
WORKDIR /opt/seurat-pixi
RUN pixi install --frozen

FROM ghcr.io/scilifelabdatacentre/serve-rstudio:250304-1611

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

COPY --from=rosetta-fix /libnosigtrap.so /opt/rossetafix/libnosigtrap.so
ENV LD_PRELOAD=/opt/rossetafix/libnosigtrap.so

COPY scripts/install_seurat_bioc.sh /tmp/scripts/

RUN /tmp/scripts/install_seurat_bioc.sh

# Replace the old conda-lock install with the Pixi-built environment
COPY --from=seurat-env /opt/seurat-pixi/.pixi /opt/seurat-pixi/.pixi
RUN mkdir -p /usr/local/conda/envs \
 && ln -s /opt/seurat-pixi/.pixi/envs/default /usr/local/conda/envs/seurat

# R, Rscript and the basilisk python are on PATH for terminal sessions
ENV PATH="/usr/local/conda/envs/seurat/bin:${PATH}"
ENV R_HOME="/usr/local/conda/envs/seurat/lib/R"

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
