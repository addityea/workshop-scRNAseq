# syntax=docker/dockerfile:1
# Rosetta fork() fix (macOS 26+): compile the SIGTRAP interposer, then bake
# it into the amd64 course image. Without it, Jupyter kernels in
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

# ---- Scanpy environment from Pixi, locked and installed at build time ----
# Conda-style envs hardcode absolute paths, so the env is built at the exact
# path it will run at (/home/jovyan/.pixi) and copied 1:1.
FROM ghcr.io/prefix-dev/pixi:0.84.1 AS scanpy-env
WORKDIR /home/jovyan
COPY envs/scanpy/pixi.toml envs/scanpy/pixi.lock ./
RUN pixi install --frozen

FROM ghcr.io/scilifelabdatacentre/serve-jupyterlab-minimal:250213-1113

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV HOME=/home/${NB_USER}

USER root

COPY --from=rosetta-fix /libnosigtrap.so /opt/rossetafix/libnosigtrap.so
ENV LD_PRELOAD=/opt/rossetafix/libnosigtrap.so

COPY scripts/install_scanpy.sh /tmp/scripts/
RUN /tmp/scripts/install_scanpy.sh

ENV PATH="${HOME}/.pixi/bin:$PATH"

# Prebuilt environment + manifest (pixi run stays instant, nothing installs
# at container launch)
COPY --from=scanpy-env /home/jovyan/.pixi/envs /home/jovyan/.pixi/envs
COPY envs/scanpy/pixi.toml envs/scanpy/pixi.lock /home/jovyan/

# Configure container start
COPY scripts/scanpy-start-script.sh ${HOME}/start-script.sh
COPY scripts/download-labs.sh ${HOME}/download-labs.sh

RUN chmod a+x ${HOME}/start-script.sh && \
    chmod a+x ${HOME}/download-labs.sh

RUN mkdir -p /home/jovyan/.local/share/jupyter && \
    chown -R jovyan:users /home/jovyan

ENV PIXI_LOCKED=true

USER ${NB_USER}

# Register the course kernel into the image (also verifies the env at build)
RUN /home/jovyan/.pixi/envs/default/bin/python -m ipykernel install \
        --user --name scanpy --display-name scanpy

WORKDIR ${HOME}

EXPOSE 8888

ENTRYPOINT ["tini", "-g", "--", "./start-script.sh"]
