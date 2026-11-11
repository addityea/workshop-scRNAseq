#!/bin/bash
set -e

HOME="/home/jovyan"
ENVBIN="${HOME}/.pixi/envs/default/bin"

# The Pixi environment and the scanpy kernel are baked into the image at
# build time. Re-registering here is cheap insurance if the home dir gets
# remounted over the kernel spec.
"${ENVBIN}/python" -m ipykernel install --user --name scanpy --display-name scanpy

exec "${ENVBIN}/jupyter" lab \
    --no-browser \
    --ip=0.0.0.0 \
    --port=8888 \
    --MultiKernelManager.default_kernel_name=scanpy \
    --PasswordIdentityProvider.hashed_password='argon2:$argon2id$v=19$m=10240,t=10,p=8$v6MTLSoeu/3mJPHOmiZ1sw$pr5VMmGV7zeOd2YZWu8lgP1lSBMtVeg/Mrj2XznRPEY' \
    --IdentityProvider.token='' \
    --MappingKernelManager.kernel_info_timeout=300
