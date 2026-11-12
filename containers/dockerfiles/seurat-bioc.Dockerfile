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
RUN apt-get update \
 && apt-get install -y --no-install-recommends make \
 && rm -rf /var/lib/apt/lists/*
COPY envs/seurat/pixi.toml envs/seurat/pixi.lock /opt/seurat-pixi/
WORKDIR /opt/seurat-pixi
RUN pixi install --frozen
# Bioconductor *data* packages (payload in Bioconductor's data/annotation and
# data/experiment repositories) ship as empty stubs on bioconda; their conda
# post-link scripts do the actual install, and pixi/rattler never runs
# post-link scripts. Without this step, scater/scran/batchelor/scDblFinder/
# scmap/Signac/celldex all fail to load at runtime. The old conda-lock flow
# got these implicitly via post-links; replicate them here explicitly.
# (GO.db/org.Hs.eg.db/BSgenome/EnsDb/JASPAR are data payloads of top-level
# course packages; GenomeInfoDbData is a hard dependency of GenomeInfoDb.)
RUN /opt/seurat-pixi/.pixi/envs/default/bin/Rscript -e ' \
  data_pkgs <- c("GenomeInfoDbData", "GO.db", "org.Hs.eg.db", \
                 "BSgenome.Hsapiens.UCSC.hg38", "EnsDb.Hsapiens.v86", \
                 "JASPAR2020", "celldex"); \
  BiocManager::install(data_pkgs, lib = file.path(R.home("library")), \
                       version = "3.18", update = FALSE, ask = FALSE, Ncpus = 2); \
  missing <- data_pkgs[!vapply(data_pkgs, requireNamespace, logical(1), quietly = TRUE)]; \
  if (length(missing)) stop("Bioconductor data package install failed: ", \
                            paste(missing, collapse = ", "))'
# DoubletFinder is not packaged on conda anywhere; install it at BUILD time
# from the exact GitHub commit the lab used to pull at runtime, so student
# notebooks never compile packages during class. (presto comes from bioconda
# via pixi.toml; Azimuth likewise. SeuratDisk was in the old runtime-install
# chunk but no lab actually uses it, so it is dropped entirely.)
# SeuratData must ALSO be replaced at build time: bioconda ships only 0.2.1,
# whose LoadData() cannot serve Azimuth references (RunAzimuth dies with
# match.arg "'arg' should be one of raw/default/NA"). The pinned dev build,
# which the labs used before, supports LoadData(type="azimuth").
RUN /opt/seurat-pixi/.pixi/envs/default/bin/Rscript -e ' \
  remotes::install_github( \
    "chris-mcginnis-ucsf/DoubletFinder@3b420df68b8e2a0cc6ebd4c5c1c7ea170464c97f", \
    upgrade = FALSE, dependencies = NA); \
  remotes::install_github( \
    "satijalab/seurat-data@4dc08e022f51c324bc7bf785b1b5771d2742701d", \
    upgrade = FALSE, dependencies = FALSE); \
  pkgs <- c("DoubletFinder", "presto", "SeuratData", "Azimuth"); \
  if (packageVersion("SeuratData") < "0.2.2") stop("SeuratData still the old bioconda build"); \
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]; \
  if (length(missing)) stop("lab package install failed: ", \
                            paste(missing, collapse = ", "))'
# Bake the Azimuth reference into the image. RunAzimuth(reference="pbmcref")
# fetches it via InstallData -> install.packages(), which needs a writable R
# library; students run as jovyan and cannot write the env's site-library.
# Installing it here (as root, at build time) also removes a ~200 MB runtime
# download from the celltyping lab.
RUN /opt/seurat-pixi/.pixi/envs/default/bin/Rscript -e ' \
  SeuratData::InstallData("pbmcref"); \
  if (!requireNamespace("pbmcref.SeuratData", quietly = TRUE)) stop("pbmcref reference not baked")'

FROM ghcr.io/scilifelabdatacentre/serve-rstudio:250304-1611 AS course

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

COPY --from=rosetta-fix /libnosigtrap.so /opt/rossetafix/libnosigtrap.so
ENV LD_PRELOAD=/opt/rossetafix/libnosigtrap.so

COPY scripts/install_seurat_bioc.sh /tmp/scripts/

RUN /tmp/scripts/install_seurat_bioc.sh

# Replace the old conda-lock install with the Pixi-built environment.
# Only .pixi/envs is copied, never the whole .pixi dir: the builder's
# rattler package cache (~1.5 GB of duplicate .tar.zst) has no use at
# runtime (PIXI_LOCKED means nothing installs at launch).
COPY --from=seurat-env /opt/seurat-pixi/.pixi/envs /opt/seurat-pixi/.pixi/envs
RUN mkdir -p /usr/local/conda/envs \
 && ln -s /opt/seurat-pixi/.pixi/envs/default /usr/local/conda/envs/seurat

# R, Rscript and the basilisk python are on PATH for terminal sessions
ENV PATH="/usr/local/conda/envs/seurat/bin:${PATH}"
ENV R_HOME="/usr/local/conda/envs/seurat/lib/R"
# /etc/profile in the base rebuilds PATH for login shells, so also install a
# profile.d snippet that re-prepends the course env.
COPY scripts/seurat-env-profile.sh /etc/profile.d/zz-seurat-env.sh

# Configure container start
COPY scripts/seurat-start-script.sh ${HOME}/start-script.sh
COPY scripts/download-labs.sh ${HOME}/download-labs.sh

RUN chown -R jovyan:users ${HOME} \
    && chmod a+x ${HOME}/start-script.sh \
    && chmod a+x ${HOME}/download-labs.sh

USER jovyan

RUN mkdir -p ${HOME}/work \
    && chown -R jovyan:users ${HOME}/work \
    && { [ -f ~/.bashrc ] && cp ~/.bashrc ~/.bash_profile || touch ~/.bash_profile; }

WORKDIR ${HOME}

EXPOSE 8787

ENTRYPOINT ["/tini", "-g", "--", "./start-script.sh"]

# ---- Size trims applied in this image ----
# 1. Only .pixi/envs is copied (builder's rattler cache, ~1.5 GB, dropped).
# 2. Layer flattening (below): image size is the SUM of all layers, so dead
#    weight from the old conda-lock flow and deleted files still shipped.
#    The final stage rewrites the assembled root filesystem as one flattened
#    layer; the config the runtime needs is re-declared. The base's PASSWORD
#    env is deliberately not re-declared: DISABLE_AUTH=1 (the course setup)
#    means the start script never reads it.
# This stage is the default build target, so GitHub Actions builds the same
# flattened image without any workflow change.
FROM scratch
COPY --from=course / /
ENV PATH="/usr/local/conda/envs/seurat/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    USER=jovyan \
    GROUP=users \
    UID=1000 \
    DISABLE_AUTH=1 \
    HOME=/home/jovyan \
    R_HOME=/usr/local/conda/envs/seurat/lib/R \
    LD_PRELOAD=/opt/rossetafix/libnosigtrap.so
USER jovyan
WORKDIR /home/jovyan
EXPOSE 8787
ENTRYPOINT ["/tini", "-g", "--", "./start-script.sh"]
