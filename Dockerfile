# syntax=docker/dockerfile:1

# Foundry toolchain with the contracts built in. docker-compose.yml runs the
# tests and a local anvil chain from it.
#
#   docker build -t onchain-census-contract .
#   docker run --rm onchain-census-contract "forge test"
#
# The submodules under lib/ must be checked out
# (git submodule update --init --recursive).

ARG FOUNDRY_VERSION=v1.8.3
FROM ghcr.io/foundry-rs/foundry:${FOUNDRY_VERSION}

USER root
RUN install -d -o foundry -g foundry /app
USER foundry
WORKDIR /app

COPY --chown=foundry:foundry . .
# Fetches solc and compiles, so containers start with a warm cache.
RUN forge build

# The base image runs its arguments through /bin/sh -c.
CMD ["forge test"]
