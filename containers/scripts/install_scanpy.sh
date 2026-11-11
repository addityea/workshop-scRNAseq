#!/bin/bash

set -e

## Build ARGs
NCPUS=${NCPUS:--1}

## Function to install apt packages only if they are not installed
function apt_install() {
    if ! dpkg -s "$@" >/dev/null 2>&1; then
        if [ "$(find /var/lib/apt/lists/* | wc -l)" = "0" ]; then
            apt-get update
        fi
        apt-get install -y --no-install-recommends "$@"
    fi
}

## curl/git/jq are what the labs and download-labs.sh actually use.
## Slimmed down: the gcc/g++/libfmt-dev toolchain and the quarto-cli
## (~400 MB) were never needed by the Scanpy labs. The compiled labs
## students download are .ipynb; qmd compilation happens in the separate
## site image (scripts/compile.sh uses DOCKER_SITE).
apt_install \
    curl \
    jq \
    git

## Install Pixi
curl -fsSL https://pixi.sh/install.sh | bash

## Clean up
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/downloaded_packages
