#!/bin/bash

# R and all course packages live in the Pixi environment that is baked into
# the image and exposed at /usr/local/conda/envs/seurat (the path basilisk
# uses in the integration labs). No conda needed: the environment is simply
# on PATH.

SEURAT_ENV="/usr/local/conda/envs/seurat"
export PATH="${SEURAT_ENV}/bin:${PATH}"
export R_HOME="${SEURAT_ENV}/lib/R"

echo "Using R: $(which R)"
echo "Starting server..."

/usr/lib/rstudio-server/bin/rserver \
  --auth-none=${DISABLE_AUTH} \
  --rsession-ld-library-path=${SEURAT_ENV}/lib \
  --rsession-which-r=${SEURAT_ENV}/bin/R \
  --server-daemonize=0 \
  --server-user=${USER} \
  --server-working-dir=${HOME} \
  --www-address=0.0.0.0 \
  --www-port=8787
