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

FROM ghcr.io/scilifelabdatacentre/serve-jupyterlab-minimal:250213-1113 AS course

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV HOME=/home/${NB_USER}

USER root

COPY --from=rosetta-fix /libnosigtrap.so /opt/rossetafix/libnosigtrap.so
ENV LD_PRELOAD=/opt/rossetafix/libnosigtrap.so

COPY scripts/install_scanpy.sh /tmp/scripts/
RUN /tmp/scripts/install_scanpy.sh

ENV PATH="${HOME}/.pixi/envs/default/bin:${HOME}/.pixi/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Prebuilt environment + manifest (pixi run stays instant, nothing installs
# at container launch). --chown matters for image size: a later `chown -R`
# over these files would re-copy the whole env into a second layer (~3 GB of
# phantom duplicate; see "size trims" below).
COPY --chown=jovyan:users --from=scanpy-env /home/jovyan/.pixi/envs /home/jovyan/.pixi/envs
COPY --chown=jovyan:users envs/scanpy/pixi.toml envs/scanpy/pixi.lock /home/jovyan/

# The serve-jupyterlab-minimal base carries a full conda installation
# (/opt/conda) whose only job was to run JupyterLab; the Pixi env ships
# JupyterLab now, so conda goes away entirely: students' terminal python/pip
# resolve to the course env, no "(base)" prompt, and the image loses ~850 MB.
# The base's HEALTHCHECK runs /etc/jupyter/docker_healthcheck.py through
# python3, which lived in conda, so it is re-pointed at the Pixi python.
RUN rm -rf /opt/conda && \
    sed -i '/conda shell.bash hook/d; /conda initialize/d' \
        /etc/skel/.bashrc /home/jovyan/.bashrc 2>/dev/null || true

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
    CMD /home/jovyan/.pixi/envs/default/bin/python /etc/jupyter/docker_healthcheck.py || exit 1

# Configure container start
COPY scripts/scanpy-start-script.sh ${HOME}/start-script.sh
COPY scripts/download-labs.sh ${HOME}/download-labs.sh

RUN chmod a+x ${HOME}/start-script.sh && \
    chmod a+x ${HOME}/download-labs.sh

# Only chown the paths that are actually root-owned at this point. Never
# `chown -R /home/jovyan` after the env COPY: it re-writes every env file
# into a fresh ~3 GB phantom layer (.pixi/envs is already jovyan-owned via
# COPY --chown; only the .pixi dir itself and its bin/ are root's).
RUN mkdir -p /home/jovyan/.local/share/jupyter && \
    chown jovyan:users /home/jovyan /home/jovyan/.local /home/jovyan/.local/share /home/jovyan/.local/share/jupyter /home/jovyan/.pixi && \
    chown -R jovyan:users /home/jovyan/.cache /home/jovyan/.pixi/bin && \
    chown jovyan:users /home/jovyan/start-script.sh /home/jovyan/download-labs.sh

ENV PIXI_LOCKED=true

USER ${NB_USER}

# Register the course kernel into the image (also verifies the env at build)
RUN /home/jovyan/.pixi/envs/default/bin/python -m ipykernel install \
        --user --name scanpy --display-name scanpy

WORKDIR ${HOME}

EXPOSE 8888

ENTRYPOINT ["tini", "-g", "--", "./start-script.sh"]

# ---- Size trims applied in this image ----
# 1. chown -R after COPY of the 3 GB env re-wrote every file into a phantom
#    duplicate layer (~3 GB). Fixed via COPY --chown.
# 2. Conda (847 MB) removed outright (JupyterLab ships in the Pixi env).
# 3. Layer flattening (below): image size is the SUM of all layers, so files
#    the base image or our RUNs deleted (conda, apt lists) still shipped as
#    dead weight. The final stage rewrites the assembled root filesystem as
#    one flattened layer; every config the runtime needs is re-declared.
# This stage is the default build target, so GitHub Actions builds the same
# flattened image without any workflow change.
FROM scratch
COPY --from=course / /
ENV PATH="/home/jovyan/.pixi/envs/default/bin:/home/jovyan/.pixi/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    SHELL=/bin/bash \
    NB_USER=jovyan \
    NB_UID=1000 \
    NB_GID=100 \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    HOME=/home/jovyan \
    JUPYTER_PORT=8888 \
    LD_PRELOAD=/opt/rossetafix/libnosigtrap.so \
    PIXI_LOCKED=true
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
    CMD /home/jovyan/.pixi/envs/default/bin/python /etc/jupyter/docker_healthcheck.py || exit 1
USER jovyan
WORKDIR /home/jovyan
EXPOSE 8888
ENTRYPOINT ["tini", "-g", "--", "./start-script.sh"]
