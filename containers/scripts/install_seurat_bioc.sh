#!/bin/bash

## Exit on failure
set -euo pipefail

## Build ARGs
QUARTO_VERSION="1.3.450"
TINI_VERSION="v0.19.0"

## Install apt packages
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    binutils \
    ca-certificates \
    curl \
    libglpk-dev \
    libhdf5-dev \
    libodbc1 \
    libxml2 \
    libxt6 \
    locales \
    patch \
    vim

apt-get update && apt-get install -y git

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen

## NOTE: the old ppa:ubuntu-toolchain-r/test repo (for a newer libstdc++6)
## has been retired upstream; the PPA lookup broke the build. The conda/Pixi
## env carries its own libstdc++ via RPATH, so the system one is not used
## by R. Dropping the PPA lines entirely.

## Install tini
curl -o /tini -sL https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini
chmod +x /tini

## Install quarto cli
curl -o quarto-linux-amd64.deb -sL https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb \
    && apt-get install -y ./quarto-linux-amd64.deb \
    && rm -rf ./quarto-linux-amd64.deb \

## Install Miniconda
## Only the base conda is needed now: the seurat env itself comes from
## Pixi (see Dockerfile), and the start script still activates it via
## `conda activate seurat`. mamba/conda-lock removed (no longer used,
## saves several hundred MB).
curl -o ${HOME}/miniconda.sh -sL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash ${HOME}/miniconda.sh -bfp /usr/local/conda
rm -rf ${HOME}/miniconda.sh

/usr/local/conda/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
/usr/local/conda/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r

## Init conda for root and jovyan users
/usr/local/conda/bin/conda init bash
su - ${USER} -c "/usr/local/conda/bin/conda init bash"
source ${HOME}/.bashrc

## Clean up
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/downloaded_packages
