FROM ghcr.io/prefix-dev/pixi:latest AS build

RUN mkdir -p /app

COPY envs/scanpy/pixi.toml /app/
COPY envs/scanpy/pixi.lock /app/

WORKDIR /app
RUN pixi install
RUN pixi shell-hook > /shell-hook.sh
RUN echo 'exec "$@"' >> /shell-hook.sh

FROM ubuntu:latest AS production
RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    curl \
    libssl-dev \
    jq \
    libfmt-dev \
    git
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy Pixi environment  
COPY --from=build /app/.pixi/envs/default /app/.pixi/envs/default
COPY --from=build /shell-hook.sh /shell-hook.sh

# Create non-root user (uid/gid 1001 to avoid conflicts)
RUN groupadd -g 1001 aditya && \
    useradd -u 1001 -g 1001 -m -s /bin/bash -G video aditya && \
    chown -R aditya:aditya /app/.pixi /shell-hook.sh
# Remove /root/.pixi/bin from PATH to prevent accidental usage of root's Pixi environment
ENV PATH="/app/.pixi/envs/default/bin:${PATH}"
# Configure container start

COPY scripts/download-labs.sh /download-labs.sh

RUN chmod a+x /download-labs.sh

ENV PIXI_LOCKED=true
ENV PIXI_CACHE_DIR=/work/.cache/rattler/cache
# Make /root/.pixi/bin accessible to the non-root user
RUN mkdir -p /root/.pixi/bin && chmod -R 755 /root && chown -R aditya:aditya /root
# Switch to non-root user
USER aditya
RUN . /shell-hook.sh && python -m ipykernel install --user --name=scanpy --display-name "scanpy"

WORKDIR /work
EXPOSE 8888

CMD ["/bin/bash", "-c", "source /shell-hook.sh && exec jupyter lab --MultiKernelManager.default_kernel_name=scanpy --ip=0.0.0.0 --no-browser --port=8888 --PasswordIdentityProvider.hashed_password='argon2:$argon2id$v=19$m=10240,t=10,p=8$v6MTLSoeu/3mJPHOmiZ1sw$pr5VMmGV7zeOd2YZWu8lgP1lSBMtVeg/Mrj2XznRPEY' --IdentityProvider.token='' --MappingKernelManager.kernel_info_timeout=300"]
