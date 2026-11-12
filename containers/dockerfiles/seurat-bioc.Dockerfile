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
